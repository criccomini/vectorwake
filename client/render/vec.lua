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
local attach, reset, rebind = vwbuf.attach, vwbuf.reset, vwbuf.rebind
local w_tri, w_tri_fade = vwbuf.tri, vwbuf.tri_fade
local w_quad, w_rect, finish = vwbuf.quad, vwbuf.rect, vwbuf.finish

-- url: the mesh component to feed. capacity: vertices, which is three per
-- triangle and the hard ceiling on how much a layer can draw in a frame.
--
-- `px` is how much of this layer's coordinate space one screen pixel covers,
-- and it is what lets a stroke know how thin it is allowed to get. One is
-- right for a layer drawn in pixels, which the interface is; a world layer is
-- told its own by whoever owns the camera, because only that knows the zoom.
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
        px = 1,
        n = 0,        -- vertices written, as of the last flush
        dropped = 0,
    }, Layer)
end

function Layer:reset()
    reset(self.id)
    -- A scissor belongs to the frame that set it. Uncovering the writers here
    -- means one cannot outlive the frame that asked for it, however that frame
    -- ended. See `Layer:clip`.
    self.tri, self.tri_fade, self.quad, self.rect = nil, nil, nil, nil
end

-- Give this layer a different capacity, keeping the id every draw call holds.
--
-- A world layer is sized against how much world the camera can see, and that
-- is a property of the window rather than of the build, so it changes when
-- somebody resizes theirs. The buffer is replaced and the mesh re-pointed at
-- it; what is drawn next frame is whatever the next build writes, which is why
-- the caller has to follow this with one.
function Layer:resize(capacity)
    if capacity == self.cap then return end
    local buf = buffer.create(capacity, {
        {name = STREAM_POS, type = buffer.VALUE_TYPE_FLOAT32, count = 3},
        {name = STREAM_COL, type = buffer.VALUE_TYPE_FLOAT32, count = 4},
    })
    rebind(self.id, buf)
    self.buf = buf
    self.cap = capacity
    self.n = 0
    self.dropped = 0
    resource.set_buffer(self.res, buf)
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
--
-- Never thinner than a pixel. A rect has hard edges, so a stroke under one
-- pixel covers a pixel center or misses it on the luck of where the frame
-- happens to sit: the podium's phrase chips, stroked at 0.9 on a density-1
-- screen, drew three edges and lost their tops, every chip alike because
-- every chip shares one row. A segment gets away with the same width because
-- its edges carry falloff; a rect does not, so the floor lives here.
function Layer:frame(x, y, w, h, t, col)
    if t < 1 then t = 1 end
    self:rect(x, y, w, t, col)
    self:rect(x, y + h - t, w, t, col)
    self:rect(x, y + t, t, h - 2 * t, col)
    self:rect(x + w - t, y + t, t, h - 2 * t, col)
end

-- A thick line segment. Width is total, centered on the line.
--
-- `cap` extends both ends by half the width. Corners are not mitred here, so
-- an outline leaves a notch at every vertex where two quads meet at an angle;
-- a capped segment closes it. The quad is the same quad, only longer, so the
-- fix costs nothing.
--
-- The edges carry a pixel of falloff, and the reason is that this game draws
-- almost nothing else. A wall face is a line 0.7 pixels wide, and a hard edge
-- that narrow does not have a dim version: the pixel center is inside the quad
-- or it is not, so as the camera slides under it the line switches off and on.
-- Measured on a converted map, sliding the camera an eighth of a pixel at a
-- time, the light on screen swung by fifteen percent from one frame to the
-- next and a lit pixel could change by a hundred levels. That is the flicker
-- you see off a wall when you fly past it.
--
-- So: never thinner than a pixel, dimmed by whatever it was widened by so it
-- keeps the light it had, and a pixel of ramp on each side. The profile
-- integrates to exactly what the hard quad did. It is the same shape a line
-- rasteriser with coverage would produce, drawn as geometry because the alpha
-- the browser gives us is one sample per pixel and no argument.
--
-- Cheaper than the alternative, too. Four multisamples cost fill rate on every
-- pixel of every layer and still left the swing at nine percent; this costs
-- about half again as many triangles on the layers that stroke, and beat
-- sixteen samples.
local dimmed = {0, 0, 0, 0}
function Layer:seg(x1, y1, x2, y2, width, col, cap)
    local dx, dy = x2 - x1, y2 - y1
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1e-6 then return end
    local px = self.px
    local ux, uy = dx / len, dy / len
    if cap then
        local ex, ey = ux * width * 0.5, uy * width * 0.5
        x1, y1, x2, y2 = x1 - ex, y1 - ey, x2 + ex, y2 + ey
    end
    local w, a = width, col[4]
    if w < px then a = a * w / px w = px end
    -- The core is what is left after a pixel of ramp is taken off each side,
    -- and for most of the lines in this game there is nothing left of it.
    local hc, ho = (w - px) * 0.5, (w + px) * 0.5
    local cx, cy = -uy * hc, ux * hc
    local ox, oy = -uy * ho, ux * ho
    -- A dimmed color is written into one table that is never handed on,
    -- rather than made fresh. The extension reads it during the call and keeps
    -- nothing, and a stroke is the most frequent thing this client does: at
    -- one table apiece a busy frame was several thousand of them for the
    -- collector to walk, in an interpreter with no generational anything.
    local c = col
    if a ~= col[4] then
        dimmed[1], dimmed[2], dimmed[3], dimmed[4] = col[1], col[2], col[3], a
        c = dimmed
    end
    if hc > 1e-6 then
        self:quad(x1 + cx, y1 + cy, x2 + cx, y2 + cy,
                  x2 - cx, y2 - cy, x1 - cx, y1 - cy, c)
    end
    self:tri_fade(x1 + cx, y1 + cy, 1, x2 + cx, y2 + cy, 1,
                  x2 + ox, y2 + oy, 0, c)
    self:tri_fade(x1 + cx, y1 + cy, 1, x2 + ox, y2 + oy, 0,
                  x1 + ox, y1 + oy, 0, c)
    self:tri_fade(x1 - cx, y1 - cy, 1, x2 - cx, y2 - cy, 1,
                  x2 - ox, y2 - oy, 0, c)
    self:tri_fade(x1 - cx, y1 - cy, 1, x2 - ox, y2 - oy, 0,
                  x1 - ox, y1 - oy, 0, c)
end

-- A segment that fades across its width rather than along its length: full
-- alpha on the line itself, nothing at either edge.
--
-- What every wide stroke of a bloom wants. A flat quad at five percent alpha
-- reads as a band with a hard edge rather than as light coming off something,
-- which is the whole difference between a glow and a halo drawn as a box.
function Layer:seg_glow(x1, y1, x2, y2, width, a, col)
    local dx, dy = x2 - x1, y2 - y1
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1e-6 then return end
    local h = width * 0.5
    local nx, ny = -dy / len * h, dx / len * h
    local ex, ey = dx / len * h, dy / len * h
    x1, y1, x2, y2 = x1 - ex, y1 - ey, x2 + ex, y2 + ey
    self:tri_fade(x1, y1, a, x2, y2, a, x2 + nx, y2 + ny, 0, col)
    self:tri_fade(x1, y1, a, x2 + nx, y2 + ny, 0, x1 + nx, y1 + ny, 0, col)
    self:tri_fade(x1, y1, a, x2, y2, a, x2 - nx, y2 - ny, 0, col)
    self:tri_fade(x1, y1, a, x2 - nx, y2 - ny, 0, x1 - nx, y1 - ny, 0, col)
end

-- A skirt hanging off one side of a segment: full alpha on the line, nothing
-- at `dx, dy` away from it. What a wall face throws, in both directions, and
-- the open-ended cousin of glow_band.
function Layer:skirt(x1, y1, x2, y2, dx, dy, a, col)
    self:tri_fade(x1, y1, a, x2, y2, a, x2 + dx, y2 + dy, 0, col)
    self:tri_fade(x1, y1, a, x2 + dx, y2 + dy, 0, x1 + dx, y1 + dy, 0, col)
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

-- A solid, constant-width segment with horizontal ends. The brand mark uses
-- this cut so the top and bottom stay level while each diagonal is drawn.
--
-- Antialiased exactly the way `seg` is, and for the same reason: one alpha
-- sample per pixel and no argument, so a hard-edged quad two pixels wide is a
-- staircase wherever it leans. This was the one stroke in the client drawn
-- without that treatment and the only one that leans by construction, and the
-- mark's diagonals came out visibly thinner and rougher than the verticals
-- they land on -- worst at the size the mark is drawn beside the name, where
-- the stroke is about two pixels and the ramp is most of it.
--
-- The ramp is laid horizontally, like the width, so the ends stay flat. It is
-- sized so that what it comes to square to the stroke is the one pixel `seg`
-- puts there: a stroke leaning half as far across as it runs down is longer
-- than it is tall by that ratio, and the ramp has to be stretched by the same
-- ratio to land a pixel wide on the screen.
function Layer:seg_flat(x1, y1, x2, y2, width, col)
    local dx, dy = x2 - x1, y2 - y1
    local len = math.sqrt(dx * dx + dy * dy)
    -- A stroke with no fall to it has no level cut to keep, and the stretch
    -- below has nothing to divide by.
    if len < 1e-6 or math.abs(dy) < 1e-6 then return end
    local px = self.px * len / math.abs(dy)
    local w, a = width, col[4]
    if w < px then a = a * w / px w = px end
    local hc, ho = (w - px) * 0.5, (w + px) * 0.5
    local c = col
    if a ~= col[4] then
        dimmed[1], dimmed[2], dimmed[3], dimmed[4] = col[1], col[2], col[3], a
        c = dimmed
    end
    if hc > 1e-6 then
        self:quad(x1 - hc, y1, x2 - hc, y2, x2 + hc, y2, x1 + hc, y1, c)
    end
    self:tri_fade(x1 + hc, y1, 1, x2 + hc, y2, 1, x2 + ho, y2, 0, c)
    self:tri_fade(x1 + hc, y1, 1, x2 + ho, y2, 0, x1 + ho, y1, 0, c)
    self:tri_fade(x1 - hc, y1, 1, x2 - hc, y2, 1, x2 - ho, y2, 0, c)
    self:tri_fade(x1 - hc, y1, 1, x2 - ho, y2, 0, x1 - ho, y1, 0, c)
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

-- The bloom a bright thing sheds into the space around it: a wide, faint
-- halo drawn on top of whatever tight glow the thing already has.
--
-- This is the geometry answer to a post-process nobody here can test before a
-- player sees it. What a real bloom does that a drawn halo does not is sum:
-- the blurred layer adds, so two bolts crossing brighten the gap between
-- them. These sum too, because the glow pass is additive, which is most of
-- the effect for none of the risk. What is genuinely lost is bleeding off
-- large filled areas, and a game made of thin lines and small dots has
-- little of that to miss.
--
-- The center's alpha is a parameter rather than a color, because the writer
-- multiplies the two and a fresh {r,g,b,a} per bright thing per frame is a
-- table this loop cannot afford. Six segments: at these alphas nobody has
-- ever seen the polygon, and the count is the whole cost, eighteen vertices
-- a call.
local BLOOM_SEGS = 6
function Layer:bloom(x, y, r, a, col)
    local u = unit(BLOOM_SEGS)
    for i = 0, BLOOM_SEGS - 1 do
        self:tri_fade(x, y, a,
                      x + u[i * 2 + 1] * r, y + u[i * 2 + 2] * r, 0,
                      x + u[i * 2 + 3] * r, y + u[i * 2 + 4] * r, 0, col)
    end
end

-- A disc that is solid at the center and gone at the rim: a light source
-- rather than a coin. The tight one, sized to the thing it belongs to;
-- `bloom` above is the wide faint one that goes over the top of it.
function Layer:halo(x, y, r, segs, col)
    local u = unit(segs)
    for i = 0, segs - 1 do
        self:tri_fade(x, y, 1,
                      x + u[i * 2 + 1] * r, y + u[i * 2 + 2] * r, 0,
                      x + u[i * 2 + 3] * r, y + u[i * 2 + 4] * r, 0, col)
    end
end

-- Part of a ring, from a0 to a1. A crater's rim and a spawn pad's bracket are
-- both this, and neither wants the whole circle.
function Layer:arc(x, y, r, a0, a1, width, segs, col)
    local ri, ro = r - width * 0.5, r + width * 0.5
    local step = (a1 - a0) / segs
    for i = 0, segs - 1 do
        local b0, b1 = a0 + step * i, a0 + step * (i + 1)
        local c0, s0 = math.cos(b0), math.sin(b0)
        local c1, s1 = math.cos(b1), math.sin(b1)
        self:quad(x + c0 * ri, y + s0 * ri, x + c1 * ri, y + s1 * ri,
                  x + c1 * ro, y + s1 * ro, x + c0 * ro, y + s0 * ro, col)
    end
end

-- Held at the middle, never through it.
--
-- A band wider than twice its own radius has an inner edge behind the center,
-- and a negative radius does not draw a smaller ring: every inner vertex lands
-- on the far side of the middle, so each segment becomes a bow tie crossing
-- its neighbours. What that draws is a blob at the center rather than the thin
-- ring the caller asked for, and on the additive layer, where every one of
-- these overlaps counts, a wave meant to be brightest on its rim came out
-- brightest in its middle. Clamped, the inner edge collapses to the center and
-- the band is a disc, which is the honest reading of a ring that wide.
local function inner(r, width)
    local ri = r - width * 0.5
    return ri > 0 and ri or 0
end

function Layer:ring(x, y, r, width, segs, col)
    local u = unit(segs)
    local ri, ro = inner(r, width), r + width * 0.5
    for i = 0, segs - 1 do
        local c0, s0 = u[i * 2 + 1], u[i * 2 + 2]
        local c1, s1 = u[i * 2 + 3], u[i * 2 + 4]
        self:quad(x + c0 * ri, y + s0 * ri, x + c1 * ri, y + s1 * ri,
                  x + c1 * ro, y + s1 * ro, x + c0 * ro, y + s0 * ro, col)
    end
end

-- A shockwave: bright on the ring, gone on both sides of it. Every wave the
-- effects layer draws starts wider than it is round, so the clamp above is
-- load-bearing here rather than defensive: this is the first frame or two of
-- every ship death and every bomb.
function Layer:ring_fade(x, y, r, width, segs, col)
    local u = unit(segs)
    local ri, ro = inner(r, width), r + width * 0.5
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

-- A ring or a part of one, carrying the pixel of falloff every stroke in this
-- game carries. See Layer:seg for what the profile is and why it is geometry
-- rather than multisampling.
--
-- Layer:arc and Layer:ring above lay hard-edged quads, which is what the
-- things they were written for wanted: a crater rim and a spawn bracket are
-- drawn once over a map and read at a distance. A control under a thumb is
-- neither. Its rim is the whole of its edge, it sits still on the glass where
-- the eye can settle on it, and a hard-edged band a couple of pixels wide is
-- exactly the case the falloff exists for -- so the pads asked for this and
-- the walls went on wanting the cheap one.
--
-- Angles run the way Layer:arc's do, and a1 below a0 sweeps the other way.
-- The joints are shared rather than capped: a cap at every joint would
-- overlap its neighbour, and on a layer that adds, overlap is a bright bead
-- at every segment of what is meant to be one even stroke.
function Layer:arc_aa(x, y, r, a0, a1, width, segs, col)
    local px = self.px
    local w, a = width, col[4]
    -- Never thinner than a pixel, dimmed by whatever it was widened by, so a
    -- hairline keeps the light it had instead of blinking as it crosses one.
    if w < px then a = a * w / px w = px end
    local hc, ho = (w - px) * 0.5, (w + px) * 0.5
    local ci, co = r - hc, r + hc
    local oi, oo = r - ho, r + ho
    if ci < 0 then ci = 0 end
    if oi < 0 then oi = 0 end
    local c = col
    if a ~= col[4] then
        dimmed[1], dimmed[2], dimmed[3], dimmed[4] = col[1], col[2], col[3], a
        c = dimmed
    end
    local step = (a1 - a0) / segs
    for i = 0, segs - 1 do
        local b0, b1 = a0 + step * i, a0 + step * (i + 1)
        local c0, s0 = math.cos(b0), math.sin(b0)
        local c1, s1 = math.cos(b1), math.sin(b1)
        if hc > 1e-6 then
            self:quad(x + c0 * ci, y + s0 * ci, x + c1 * ci, y + s1 * ci,
                      x + c1 * co, y + s1 * co, x + c0 * co, y + s0 * co, c)
        end
        -- The ramp inside the core, and the one outside it.
        self:tri_fade(x + c0 * ci, y + s0 * ci, 1,
                      x + c1 * ci, y + s1 * ci, 1,
                      x + c1 * oi, y + s1 * oi, 0, c)
        self:tri_fade(x + c0 * ci, y + s0 * ci, 1,
                      x + c1 * oi, y + s1 * oi, 0,
                      x + c0 * oi, y + s0 * oi, 0, c)
        self:tri_fade(x + c0 * co, y + s0 * co, 1,
                      x + c1 * co, y + s1 * co, 1,
                      x + c1 * oo, y + s1 * oo, 0, c)
        self:tri_fade(x + c0 * co, y + s0 * co, 1,
                      x + c1 * oo, y + s1 * oo, 0,
                      x + c0 * oo, y + s0 * oo, 0, c)
    end
end

-- The whole circle of the above, at a segment count worth the radius: a ring
-- is round when its facets are under a pixel across, and that is a question
-- about how big it is rather than a number a caller should be picking.
function Layer:ring_aa(x, y, r, width, col, segs)
    self:arc_aa(x, y, r, 0, math.pi * 2,
                width, segs or self:round_segs(r), col)
end

-- How many facets a circle of this radius needs before the eye stops seeing
-- them: enough that the deepest a chord sags below the arc is under a fifth
-- of a pixel. Floored so a dot is still a dot, capped so a huge one does not
-- spend the layer.
function Layer:round_segs(r)
    local n = math.ceil(math.pi / math.acos(1 - math.min(0.2, r) / (r + 1e-6)))
    if n < 12 then n = 12 elseif n > 96 then n = 96 end
    return n
end

-- A closed outline through a flat {x1,y1,x2,y2,...} list, already transformed
-- by the caller. Corners are not mitred: at these widths the overdraw of
-- overlapping quads is invisible and mitring costs more than it buys. `cap`
-- squares off both ends of every segment, which closes the notch that overdraw
-- leaves behind at an angled corner.
function Layer:outline(pts, width, col, cap)
    local n = #pts
    for i = 1, n, 2 do
        local j = (i + 1 < n) and i + 2 or 1
        self:seg(pts[i], pts[i + 1], pts[j], pts[j + 1], width, col, cap)
    end
end

-- The bloom around a closed shape, as one skirt running from the outline out
-- to an offset copy of it: full alpha on the edge, nothing at the rim. `nrm`
-- is the outward direction at each vertex, in the same flat layout as `pts`
-- and already turned by the caller; `w` is an optional per-edge weight.
--
-- Stroking each edge separately instead, which is what `outline` does, lays
-- two overlapping quads over every corner. Additively that is a bright lozenge
-- at each vertex rather than an even haze, and it is why the old three-stroke
-- bloom looked beaded on anything sharp. One skirt is the same vertex count
-- with no overlap in it at all.
function Layer:glow_band(pts, nrm, offset, a, col, w)
    local n = #pts
    local e = 1
    for i = 1, n, 2 do
        local j = (i + 1 < n) and i + 2 or 1
        local k = w and a * w[e] or a
        local ax = pts[i] + nrm[i] * offset
        local ay = pts[i + 1] + nrm[i + 1] * offset
        local bx = pts[j] + nrm[j] * offset
        local by = pts[j + 1] + nrm[j + 1] * offset
        self:tri_fade(pts[i], pts[i + 1], k, pts[j], pts[j + 1], k, bx, by, 0,
                      col)
        self:tri_fade(pts[i], pts[i + 1], k, bx, by, 0, ax, ay, 0, col)
        e = e + 1
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

-- --- the scissor -----------------------------------------------------------
--
-- Cut everything drawn from here on against a vertical edge, until `unclip`.
--
-- One edge is the whole of it, because the one thing in this game that needs
-- cutting is the menu's column: it is docked against the left of the window
-- and a page arriving over it comes in from the right, with the fight and
-- nothing else on that side to hide it.
--
-- The cut is installed by shadowing the four writers on the instance rather
-- than by asking on every shape. Everything above and below this line ends up
-- a triangle, a quad or a rect, so cutting those four cuts strokes, discs and
-- outlines with them, and a layer nobody has clipped pays nothing at all: the
-- world pushes tens of thousands of triangles a frame through these same
-- functions and must not grow a branch for a menu animation.

-- The shape being cut, and the scratch it is cut into. One draw call is
-- clipped at a time, so one pair of these is enough for the whole client.
local kx, ky, ka = {}, {}, {}
local jx, jy, ja = {}, {}, {}

-- Sutherland-Hodgman against the one plane there is: keep what is left of
-- `edge`. Reads `n` corners from k and writes the survivors to j, in order,
-- returning how many there are. A convex shape cut by one plane comes back
-- with at most one corner more than it went in with.
local function cut(n, edge)
    local out = 0
    local ax, ay, aa = kx[n], ky[n], ka[n]
    local ain = ax <= edge
    for i = 1, n do
        local bx, by, ba = kx[i], ky[i], ka[i]
        local bin = bx <= edge
        -- The corner where this side crosses, which belongs to both halves
        -- and is kept by this one whichever way the crossing runs.
        if ain ~= bin then
            local t = (edge - ax) / (bx - ax)
            out = out + 1
            jx[out], jy[out], ja[out] =
                edge, ay + (by - ay) * t, aa + (ba - aa) * t
        end
        if bin then
            out = out + 1
            jx[out], jy[out], ja[out] = bx, by, ba
        end
        ax, ay, aa, ain = bx, by, ba, bin
    end
    return out
end

local function clip_tri(self, x1, y1, x2, y2, x3, y3, col)
    local edge = self.clip_r
    if x1 <= edge and x2 <= edge and x3 <= edge then
        return w_tri(self.id, x1, y1, x2, y2, x3, y3, col)
    end
    if x1 > edge and x2 > edge and x3 > edge then return end
    kx[1], ky[1], ka[1] = x1, y1, 1
    kx[2], ky[2], ka[2] = x2, y2, 1
    kx[3], ky[3], ka[3] = x3, y3, 1
    -- What is left is a quadrilateral as often as a triangle, so it goes out
    -- as a fan off the first corner.
    for i = 3, cut(3, edge) do
        w_tri(self.id, jx[1], jy[1], jx[i - 1], jy[i - 1], jx[i], jy[i], col)
    end
end

-- The alpha rides along the cut edge the way the GPU carries it across the
-- face, so a falloff that crosses the line keeps its gradient rather than
-- ending on whatever the nearest corner happened to hold.
local function clip_tri_fade(self, x1, y1, a1, x2, y2, a2, x3, y3, a3, col)
    local edge = self.clip_r
    if x1 <= edge and x2 <= edge and x3 <= edge then
        return w_tri_fade(self.id, x1, y1, a1, x2, y2, a2, x3, y3, a3, col)
    end
    if x1 > edge and x2 > edge and x3 > edge then return end
    kx[1], ky[1], ka[1] = x1, y1, a1
    kx[2], ky[2], ka[2] = x2, y2, a2
    kx[3], ky[3], ka[3] = x3, y3, a3
    for i = 3, cut(3, edge) do
        w_tri_fade(self.id, jx[1], jy[1], ja[1],
                   jx[i - 1], jy[i - 1], ja[i - 1],
                   jx[i], jy[i], ja[i], col)
    end
end

local function clip_quad(self, x1, y1, x2, y2, x3, y3, x4, y4, col)
    local edge = self.clip_r
    if x1 <= edge and x2 <= edge and x3 <= edge and x4 <= edge then
        return w_quad(self.id, x1, y1, x2, y2, x3, y3, x4, y4, col)
    end
    if x1 > edge and x2 > edge and x3 > edge and x4 > edge then return end
    kx[1], ky[1], ka[1] = x1, y1, 1
    kx[2], ky[2], ka[2] = x2, y2, 1
    kx[3], ky[3], ka[3] = x3, y3, 1
    kx[4], ky[4], ka[4] = x4, y4, 1
    for i = 3, cut(4, edge) do
        w_tri(self.id, jx[1], jy[1], jx[i - 1], jy[i - 1], jx[i], jy[i], col)
    end
end

local function clip_rect(self, x, y, w, h, col)
    if x + w > self.clip_r then w = self.clip_r - x end
    if w <= 0 then return end
    w_rect(self.id, x, y, w, h, col)
end

function Layer:clip(right)
    self.clip_r = right
    self.tri, self.tri_fade, self.quad, self.rect =
        clip_tri, clip_tri_fade, clip_quad, clip_rect
end

-- Back to the layer's own writers. Nil uncovers them: the methods live on the
-- metatable and the scissor was only ever shadowing them from the instance.
function Layer:unclip()
    self.tri, self.tri_fade, self.quad, self.rect = nil, nil, nil, nil
end

return M
