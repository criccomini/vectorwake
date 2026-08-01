-- Vector geometry, built in Lua and handed to the GPU as one mesh per layer.
--
-- The client used to draw through `draw_debug3d`, which is one pixel wide, one
-- blend mode, and -- the part that mattered -- compiled out of release builds
-- entirely, so a shipped bundle drew an empty arena. Everything visible now
-- goes through here instead: triangles in a dynamic vertex buffer, uploaded
-- once per layer per frame.
--
-- A layer is a mesh component plus the buffer behind it. Triangles are
-- appended as the frame is described, the unused tail is degenerated to
-- nothing, and `flush` hands the whole thing over. Nothing here knows what a
-- ship is; it knows lines, discs and quads.
--
-- Speed matters more than elegance in this file, and the reason is the
-- platform: HTML5 builds run Lua 5.1, not LuaJIT. Indexing a buffer stream
-- from Lua is one call into C per float -- twenty-one per triangle, fifty
-- thousand a frame -- which measured about five milliseconds a frame of pure
-- boundary crossing, more than the simulation and the interface put together.
-- The shapes are described here and written by `vwbuf` in the native
-- extension, one call each.

local M = {}

local STREAM_POS = hash("position")
local STREAM_COL = hash("color")

local Layer = {}
Layer.__index = Layer

-- Writing is the native extension's job. Every float used to be its own call
-- into C -- twenty-one per triangle, fifty thousand a frame -- and on the web,
-- where Lua 5.1 runs the interpreter rather than LuaJIT, that alone was about
-- five milliseconds a frame. It is one call per shape now. The arithmetic
-- that decides where a shape goes is still here, where it can be read.
local attach, reset = vwbuf.attach, vwbuf.reset
local w_tri, w_tri_fade = vwbuf.tri, vwbuf.tri_fade
local w_quad, w_rect, finish = vwbuf.quad, vwbuf.rect, vwbuf.finish

-- The busiest frame this layer has had, everything it has refused to draw for
-- want of room, and what it holds. A capacity set too tight does not raise
-- anything: geometry just stops appearing.
function Layer:stats()
    return vwbuf.stats(self.id)
end

-- url: the mesh component to feed. capacity: vertices, which is three per
-- triangle and the hard ceiling on how much a layer can draw in a frame.
function M.layer(url, capacity)
    local buf = buffer.create(capacity, {
        {name = STREAM_POS, type = buffer.VALUE_TYPE_FLOAT32, count = 3},
        {name = STREAM_COL, type = buffer.VALUE_TYPE_FLOAT32, count = 4},
    })
    return setmetatable({
        buf = buf,
        id = attach(buf),
        res = go.get(url, "vertices"),
        cap = capacity,
        n = 0,        -- vertices written, as of the last flush
        dropped = 0,
    }, Layer)
end

function Layer:reset()
    reset(self.id)
end

-- Degenerate whatever a busier frame left behind, then upload. A triangle
-- whose three corners are the same point covers no pixels, which is a cheaper
-- way to erase than rebuilding the buffer at the exact size every frame.
function Layer:flush()
    self.n, self.dropped = finish(self.id)
    resource.set_buffer(self.res, self.buf)
end

-- --- primitives ------------------------------------------------------------

function Layer:tri(x1, y1, x2, y2, x3, y3, col)
    w_tri(self.id, x1, y1, x2, y2, x3, y3, col)
end

-- A triangle whose corners carry their own alpha. Every soft edge in the game
-- -- glow falloff, trail fade, blast rim -- is this and nothing more.
function Layer:tri_fade(x1, y1, a1, x2, y2, a2, x3, y3, a3, col)
    w_tri_fade(self.id, x1, y1, a1, x2, y2, a2, x3, y3, a3, col)
end

function Layer:quad(x1, y1, x2, y2, x3, y3, x4, y4, col)
    w_quad(self.id, x1, y1, x2, y2, x3, y3, x4, y4, col)
end

-- Axis-aligned, from a corner. Screen-space panels and bars are all this.
function Layer:rect(x, y, w, h, col)
    w_rect(self.id, x, y, w, h, col)
end

-- A one-pixel-thick frame, drawn as four rects rather than an outline, so it
-- lands on exact pixels the way a CSS border does.
function Layer:frame(x, y, w, h, t, col)
    self:rect(x, y, w, t, col)
    self:rect(x, y + h - t, w, t, col)
    self:rect(x, y + t, t, h - 2 * t, col)
    self:rect(x + w - t, y + t, t, h - 2 * t, col)
end

-- A thick line segment. Width is total, centred on the line.
function Layer:seg(x1, y1, x2, y2, width, col)
    local dx, dy = x2 - x1, y2 - y1
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1e-6 then return end
    local nx, ny = -dy / len * width * 0.5, dx / len * width * 0.5
    self:quad(x1 + nx, y1 + ny, x2 + nx, y2 + ny,
              x2 - nx, y2 - ny, x1 - nx, y1 - ny, col)
end

-- A segment that fades along its length: the trail behind a bolt, the taper
-- of a thruster flame.
function Layer:seg_fade(x1, y1, x2, y2, w1, w2, a1, a2, col)
    local dx, dy = x2 - x1, y2 - y1
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1e-6 then return end
    local ux, uy = -dy / len, dx / len
    local ax, ay = ux * w1 * 0.5, uy * w1 * 0.5
    local bx, by = ux * w2 * 0.5, uy * w2 * 0.5
    self:tri_fade(x1 + ax, y1 + ay, a1, x2 + bx, y2 + by, a2,
                  x2 - bx, y2 - by, a2, col)
    self:tri_fade(x1 + ax, y1 + ay, a1, x2 - bx, y2 - by, a2,
                  x1 - ax, y1 - ay, a1, col)
end

-- Unit circles, cached per segment count. Trigonometry inside a draw loop is
-- the one cost this file can remove outright.
local rings = {}
local function unit(segs)
    local u = rings[segs]
    if not u then
        u = {}
        for i = 0, segs do
            local a = i / segs * math.pi * 2
            u[i * 2 + 1] = math.cos(a)
            u[i * 2 + 2] = math.sin(a)
        end
        rings[segs] = u
    end
    return u
end

function Layer:disc(x, y, r, segs, col)
    local u = unit(segs)
    for i = 0, segs - 1 do
        self:tri(x, y,
                 x + u[i * 2 + 1] * r, y + u[i * 2 + 2] * r,
                 x + u[i * 2 + 3] * r, y + u[i * 2 + 4] * r, col)
    end
end

-- A disc that is solid at the centre and gone at the rim: a light source
-- rather than a coin. Additive, this is the whole bloom vocabulary.
function Layer:halo(x, y, r, segs, col)
    local u = unit(segs)
    for i = 0, segs - 1 do
        self:tri_fade(x, y, 1,
                      x + u[i * 2 + 1] * r, y + u[i * 2 + 2] * r, 0,
                      x + u[i * 2 + 3] * r, y + u[i * 2 + 4] * r, 0, col)
    end
end

function Layer:ring(x, y, r, width, segs, col)
    local u = unit(segs)
    local ri, ro = r - width * 0.5, r + width * 0.5
    for i = 0, segs - 1 do
        local c0, s0 = u[i * 2 + 1], u[i * 2 + 2]
        local c1, s1 = u[i * 2 + 3], u[i * 2 + 4]
        self:quad(x + c0 * ri, y + s0 * ri, x + c1 * ri, y + s1 * ri,
                  x + c1 * ro, y + s1 * ro, x + c0 * ro, y + s0 * ro, col)
    end
end

-- A shockwave: bright on the ring, gone on both sides of it.
function Layer:ring_fade(x, y, r, width, segs, col)
    local u = unit(segs)
    local ri, ro = r - width * 0.5, r + width * 0.5
    for i = 0, segs - 1 do
        local c0, s0 = u[i * 2 + 1], u[i * 2 + 2]
        local c1, s1 = u[i * 2 + 3], u[i * 2 + 4]
        self:tri_fade(x + c0 * ri, y + s0 * ri, 0,
                      x + c1 * ri, y + s1 * ri, 0,
                      x + c1 * r, y + s1 * r, 1, col)
        self:tri_fade(x + c0 * ri, y + s0 * ri, 0,
                      x + c1 * r, y + s1 * r, 1,
                      x + c0 * r, y + s0 * r, 1, col)
        self:tri_fade(x + c0 * r, y + s0 * r, 1,
                      x + c1 * r, y + s1 * r, 1,
                      x + c1 * ro, y + s1 * ro, 0, col)
        self:tri_fade(x + c0 * r, y + s0 * r, 1,
                      x + c1 * ro, y + s1 * ro, 0,
                      x + c0 * ro, y + s0 * ro, 0, col)
    end
end

-- A closed outline through a flat {x1,y1,x2,y2,...} list, already transformed
-- by the caller. Corners are not mitred: at these widths the overdraw of
-- overlapping quads is invisible and mitring costs more than it buys.
function Layer:outline(pts, width, col)
    local n = #pts
    for i = 1, n, 2 do
        local j = (i + 1 < n) and i + 2 or 1
        self:seg(pts[i], pts[i + 1], pts[j], pts[j + 1], width, col)
    end
end

-- A convex fill through the same list, as a fan from the first point.
function Layer:fan(pts, col)
    local n = #pts
    local x0, y0 = pts[1], pts[2]
    for i = 3, n - 2, 2 do
        self:tri(x0, y0, pts[i], pts[i + 1], pts[i + 2], pts[i + 3], col)
    end
end

M.Layer = Layer
return M
