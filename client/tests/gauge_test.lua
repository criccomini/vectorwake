-- The settings stop, which is an instrument off the panel in front of you.
--
--     lua5.1 client/tests/gauge_test.lua
--
-- Three sliders stood here first, and the mark that replaced them is the one
-- shape on the rail that is easy to draw wrong twice over.
--
-- The first way is the fill. Every solid thing this game draws is dark in the
-- body and lit at the rim, from a wall face to a hull to the world on the stop
-- beside this one, and a gauge drawn as an open curve is not a solid thing at
-- all: it floats, and at the thirteen points a sideways phone gives a rail
-- mark it stops reading as an instrument and starts reading as an eyebrow.
-- What holds it down is the flat edge it stands on, so that edge is measured
-- here rather than assumed.
--
-- The second is the redline. It went in as a bare wash, and a filled shape
-- with no edge on it is not in this interface's vocabulary anywhere: the
-- pennants on the team mark and the flag on a game row are both a faint fill
-- under a drawn line. Without the edge it read as a grey pane laid over the
-- dial. It also sat on top of the last graduation, which cost the scale a
-- quarter of itself in the one picture that was supposed to show a range.
--
-- None of that is visible to a test that reads strings, and all of it is one
-- number away from coming back.

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

-- --- a layer that keeps what it was asked for ------------------------------
--
-- Up is +y here, the way it is on the real layer once `ry` has turned the
-- mark's own downward y around. So the dome stands above its hub and anything
-- hanging under the mark has a y below the baseline's.

local H = 600
local shapes = {}
local function put(t) shapes[#shapes + 1] = t return t end

local layer = {}
function layer:seg(x1, y1, x2, y2, w, col, _)
    put({kind = "seg", ax = x1, ay = y1, bx = x2, by = y2, w = w, col = col})
end
function layer:disc(x, y, r, _, col)
    put({kind = "disc", x = x, y = y, r = r, col = col})
end
function layer:arc(x, y, r, a0, a1, w, _, col)
    put({kind = "arc", x = x, y = y, r = r, a0 = a0, a1 = a1, w = w, col = col})
end
local function pointed(kind, pts, extra)
    local o = {kind = kind, pts = {}}
    for i = 1, #pts, 2 do o.pts[#o.pts + 1] = {pts[i], pts[i + 1]} end
    for k, v in pairs(extra or {}) do o[k] = v end
    return put(o)
end
function layer:fan(pts, col) pointed("fan", pts, {col = col}) end
function layer:outline(pts, w, col, closed)
    pointed("outline", pts, {w = w, col = col, closed = closed and true or false})
end
for _, n in ipairs({"frame", "quad", "ring", "tri"}) do
    layer[n] = function() end
end

-- Two colors far enough apart to tell a body from a rim by looking.
local BG = {0.02, 0.03, 0.05, 1}
local STOP = {0.5, 0.8, 1.0, 1}
local pal = {BG = BG, a = function(c, alpha) return {c[1], c[2], c[3], alpha} end}
local function is(col, want) return col and col[1] == want[1] end

local function noop() end
local draw = require("arena.ui_menu_marks").new({
    frame = {layer = layer, scale = 1}, palette = pal,
    ry = function(y, h) return H - y - (h or 0) end,
    rect = noop, pilot_mark = noop, thumb = noop, rivet_mark = noop,
})

local CX, CY, R = 300, 300, 40
draw("settings", CX, CY, R, STOP)

local function only(kind, pick)
    local out = {}
    for _, sh in ipairs(shapes) do
        if sh.kind == kind and (pick == nil or pick(sh)) then out[#out + 1] = sh end
    end
    return out
end

-- --- it is a solid body, not a curve ---------------------------------------

local body = only("fan", function(sh) return is(sh.col, BG) end)
local rim = only("arc", function(sh) return is(sh.col, STOP) and sh.r > R end)
check("the dial has a body under it", #body == 1, #body .. " fills")
check("and a lit rim over that body", #rim == 1, #rim .. " rims")

local hub = only("disc")[1]
check("the needle turns on a hub", hub ~= nil)

if #body == 1 and #rim == 1 and hub then
    -- The rim is the half circle the body fills, so the two are one shape seen
    -- twice rather than two shapes that happen to overlap.
    check("the rim closes the body it lights",
          math.abs(rim[1].x - hub.x) < 0.01 and math.abs(rim[1].y - hub.y) < 0.01
          and math.abs(rim[1].a1 - rim[1].a0 - math.pi) < 1e-6,
          string.format("%.1f,%.1f sweeping %.2f", rim[1].x, rim[1].y,
                        rim[1].a1 - rim[1].a0))

    -- What stops it floating. A segment as wide as the dial, level, through
    -- the hub: the one flat edge on this rail, and the whole of why the mark
    -- keeps its shape when it is drawn small.
    local base
    for _, sh in ipairs(only("seg")) do
        if math.abs(sh.ay - sh.by) < 0.01 and math.abs(sh.ay - hub.y) < 0.01
            and math.abs(sh.bx - sh.ax) > rim[1].r * 1.9 then
            base = sh
        end
    end
    check("it stands on a flat edge as wide as the dial", base ~= nil,
          base and string.format("%.1f wide", math.abs(base.bx - base.ax))
               or "no level segment through the hub")

    -- And nothing of consequence hangs under that edge, which is the claim the
    -- silhouette makes: this is the only stop on the row with a flat bottom.
    local drop = 0
    for _, sh in ipairs(shapes) do
        local ys = {}
        if sh.pts then
            for _, p in ipairs(sh.pts) do ys[#ys + 1] = p[2] end
        elseif sh.kind == "seg" then
            ys = {sh.ay - sh.w / 2, sh.by - sh.w / 2}
        elseif sh.kind == "disc" then
            ys = {sh.y - sh.r}
        elseif sh.kind == "arc" then
            -- Only the half that is drawn, and this one is drawn upward.
            ys = {sh.y}
        end
        for _, y in ipairs(ys) do
            drop = math.max(drop, hub.y - y)
        end
    end
    check("nothing of it hangs below that edge", drop < R * 0.16,
          string.format("%.2f under the line, of %d", drop, R))
end

-- --- the scale, and the band at the end of it ------------------------------

-- Every graduation is a stroke struck outward from the hub and stopping short
-- of the rim, which is what tells them from the needle and from the edge under
-- them both.
local ticks = {}
if hub then
    for _, sh in ipairs(only("seg")) do
        local ar = math.sqrt((sh.ax - hub.x) ^ 2 + (sh.ay - hub.y) ^ 2)
        local br = math.sqrt((sh.bx - hub.x) ^ 2 + (sh.by - hub.y) ^ 2)
        if ar > R * 0.3 and br > ar then
            sh.deg = math.deg(math.atan2(sh.by - hub.y, sh.bx - hub.x))
            ticks[#ticks + 1] = sh
        end
    end
end
check("the scale is drawn in four graduations", #ticks == 4,
      #ticks .. " struck outward")

local wash = only("fan", function(sh) return is(sh.col, STOP) end)
local edge = only("outline", function(sh) return sh.closed end)
check("the redline is a fill", #wash == 1, #wash .. " washes")
-- The one that went missing. A wash with no line on it is not how anything
-- else in this interface fills a shape.
check("and the redline carries an edge", #edge == 1, #edge .. " edges")

if #wash == 1 and #edge == 1 and hub and #ticks == 4 then
    check("the edge is drawn on the fill",
          #wash[1].pts == #edge[1].pts,
          #wash[1].pts .. " against " .. #edge[1].pts)

    -- Where the band sits, in degrees around the hub.
    local lo, hi
    for _, p in ipairs(edge[1].pts) do
        local d = math.deg(math.atan2(p[2] - hub.y, p[1] - hub.x))
        lo = math.min(lo or d, d)
        hi = math.max(hi or d, d)
    end
    check("it sits at the top of the scale", lo > 0 and hi < 45,
          string.format("%.0f to %.0f degrees", lo, hi))

    -- The reason it was moved. Drawn over the last graduation the scale showed
    -- three marks and a pane, which is a picture of a range with its end
    -- painted out.
    local buried = 0
    for _, t in ipairs(ticks) do
        if t.deg >= lo and t.deg <= hi then buried = buried + 1 end
    end
    check("and no graduation is buried under it", buried == 0,
          buried .. " inside the band")
end

-- --- the needle ------------------------------------------------------------

if hub and #ticks == 4 then
    local needle
    for _, sh in ipairs(only("seg")) do
        local ar = math.sqrt((sh.ax - hub.x) ^ 2 + (sh.ay - hub.y) ^ 2)
        if ar < 0.01 then needle = sh end
    end
    check("the needle is struck from the hub", needle ~= nil)
    if needle then
        local reach = math.sqrt((needle.bx - hub.x) ^ 2 + (needle.by - hub.y) ^ 2)
        local far = 0
        for _, t in ipairs(ticks) do
            far = math.max(far, math.sqrt((t.bx - hub.x) ^ 2 + (t.by - hub.y) ^ 2))
        end
        -- Long enough to be the reading rather than a fifth graduation, and
        -- heavier for the same reason. Short of the rim at the other end,
        -- because a needle touching the case is a spoke.
        check("it reaches past the graduations", reach > far + 1,
              string.format("%.1f against %.1f", reach, far))
        check("and stops short of the rim",
              reach < rim[1].r - rim[1].w, string.format(
                  "%.1f against a rim at %.1f", reach, rim[1].r))
        check("and it is drawn heavier than they are", needle.w > ticks[1].w,
              needle.w .. " against " .. ticks[1].w)
        -- Standing up among the marks. A needle lying flat reads as a shape
        -- with a line through it rather than as a reading somewhere in a range.
        local deg = math.deg(math.atan2(needle.by - hub.y, needle.bx - hub.x))
        check("and it stands up on the dial", deg > 40 and deg < 100,
              string.format("%.0f degrees", deg))
    end
end

if fails > 0 then
    print(fails .. " failed")
    os.exit(1)
end
print("all good")
