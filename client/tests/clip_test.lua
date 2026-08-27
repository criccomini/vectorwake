-- The column's scissor: what it cuts, what it leaves whole, and what a layer
-- nobody has clipped pays for it.
--
--     lua5.1 client/tests/clip_test.lua
--
-- The menu is a drawer docked against the leading edge of the window, and a
-- reading opened over a page arrives from the right. It used to arrive across
-- the fight: the page was drawn a full drawer width outside the column and
-- walked in over the arena, so on anything wider than a phone the type was
-- read over the game for the sixteenth of a second the slide takes. There was
-- nothing to cut it against, so this is that thing.
--
-- Everything this client draws is a triangle, a quad or a rect by the time it
-- reaches the buffer, which is why cutting those four cuts strokes, discs and
-- outlines with them. That is the claim worth a test: a shape nothing here
-- knows about still comes out inside the line.

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

-- The native writer, as much of it as these shapes need: every triangle, with
-- the alpha each corner carries. A quad and a rect are the triangles they are
-- turned into, which is what the writer does with them anyway.
local tris = {}
_G.vwbuf = {
    attach = function() return 1 end,
    reset = function() tris = {} end,
    rebind = function() end,
    finish = function() end,
    tri = function(_, x1, y1, x2, y2, x3, y3, col)
        local a = col[4] or 1
        tris[#tris + 1] = {{x1, y1, a}, {x2, y2, a}, {x3, y3, a}}
    end,
    tri_fade = function(_, x1, y1, a1, x2, y2, a2, x3, y3, a3, col)
        local A = col[4] or 1
        tris[#tris + 1] = {{x1, y1, a1 * A}, {x2, y2, a2 * A}, {x3, y3, a3 * A}}
    end,
    quad = function(id, x1, y1, x2, y2, x3, y3, x4, y4, col)
        _G.vwbuf.tri(id, x1, y1, x2, y2, x3, y3, col)
        _G.vwbuf.tri(id, x1, y1, x3, y3, x4, y4, col)
    end,
    rect = function(id, x, y, w, h, col)
        _G.vwbuf.quad(id, x, y, x + w, y, x + w, y + h, x, y + h, col)
    end,
}
_G.buffer = {create = function() return {} end,
             VALUE_TYPE_FLOAT32 = 1}
_G.go = {get = function() return nil end}
_G.hash = function(s) return s end

local vec = require("render.vec")
local layer = vec.layer("#none", 64)
layer.px = 1        -- the interface layer draws in pixels

local WHITE = {1, 1, 1, 1}
local EDGE = 100

-- One drawing, as the triangles it came to.
local function drew(fn)
    tris = {}
    fn()
    return tris
end

-- How much ink a set of triangles lays down. They come out of a fan over a
-- convex shape and never overlap, so the areas simply add.
local function area(t)
    local sum = 0
    for _, tri in ipairs(t) do
        local x1, y1 = tri[1][1], tri[1][2]
        local x2, y2 = tri[2][1], tri[2][2]
        local x3, y3 = tri[3][1], tri[3][2]
        sum = sum + math.abs((x2 - x1) * (y3 - y1)
                             - (x3 - x1) * (y2 - y1)) / 2
    end
    return sum
end

local function rightmost(t)
    local far = -math.huge
    for _, tri in ipairs(t) do
        for _, p in ipairs(tri) do
            if p[1] > far then far = p[1] end
        end
    end
    return far
end

local function near(a, b, tol)
    return math.abs(a - b) <= (tol or 0.01)
end

-- --- a rect --------------------------------------------------------------

do
    layer:clip(EDGE)
    local whole = drew(function() layer:rect(0, 0, 60, 20, WHITE) end)
    check("a rect that stands inside the line is drawn whole",
          near(area(whole), 1200), tostring(area(whole)))

    local cut = drew(function() layer:rect(60, 0, 80, 20, WHITE) end)
    check("one that crosses it keeps the half that is inside",
          near(area(cut), 800), tostring(area(cut)))
    check("and stops at the line", near(rightmost(cut), EDGE),
          tostring(rightmost(cut)))

    local gone = drew(function() layer:rect(140, 0, 80, 20, WHITE) end)
    check("and one wholly past it is not drawn at all", #gone == 0,
          #gone .. " triangles")
    layer:unclip()
end

-- --- a triangle and a quad -------------------------------------------------
--
-- A convex shape cut by one plane comes back with at most one corner more
-- than it went in with, so what a triangle leaves behind is as often a
-- quadrilateral as a triangle. Both go out as a fan.

do
    layer:clip(EDGE)
    -- Right-angled, 80 wide and 40 tall, with 20 of its width past the line.
    -- What is left is the trapezium up to the line: the whole area less the
    -- corner triangle, which is 20 wide and 10 tall.
    local cut = drew(function()
        layer:tri(40, 0, 120, 0, 40, 40, WHITE)
    end)
    check("a triangle cut by the line keeps the area inside it",
          near(area(cut), 80 * 40 / 2 - 20 * 10 / 2), tostring(area(cut)))
    check("and reaches the line and no further", near(rightmost(cut), EDGE),
          tostring(rightmost(cut)))

    local quad = drew(function()
        layer:quad(60, 0, 140, 0, 140, 20, 60, 20, WHITE)
    end)
    check("a quad is cut the same way", near(area(quad), 800),
          tostring(area(quad)))
    check("and stops at the line too", near(rightmost(quad), EDGE),
          tostring(rightmost(quad)))
    layer:unclip()
end

-- --- the alpha rides the cut -----------------------------------------------
--
-- Every soft edge in this game is a triangle whose corners carry their own
-- alpha, so a falloff that crosses the line has to keep its gradient: cutting
-- it at whatever the nearest corner held would put a hard edge in the one
-- shape that exists to avoid one.

do
    layer:clip(EDGE)
    -- Opaque at x = 0, gone by x = 200. The line is halfway.
    local cut = drew(function()
        layer:tri_fade(0, 0, 1, 200, 0, 0, 0, 40, 1, WHITE)
    end)
    local at_edge, other = nil, false
    for _, tri in ipairs(cut) do
        for _, p in ipairs(tri) do
            if near(p[1], EDGE) then at_edge = p[3] else other = true end
        end
    end
    check("a cut corner carries the alpha the face had there",
          at_edge ~= nil and near(at_edge, 0.5), tostring(at_edge))
    check("and the corners behind the line keep theirs", other, "none left")
    layer:unclip()
end

-- --- shapes the scissor has never heard of ---------------------------------
--
-- A disc is a fan of triangles, a stroke is a quad with two fades on it, an
-- outline is a run of both. None of them know there is a scissor; all of them
-- go through the four writers that do.

do
    layer:clip(EDGE)
    for _, drawing in ipairs({
        {"a disc", function() layer:disc(90, 40, 30, 16, WHITE) end},
        {"a ring", function() layer:ring(90, 40, 30, 4, 16, WHITE) end},
        {"a stroke", function() layer:seg(20, 40, 180, 40, 3, WHITE) end},
        -- Leaning: the flat cut is the brand mark's diagonal and draws
        -- nothing for a stroke with no fall to it.
        {"a leaning stroke",
         function() layer:seg_flat(20, 20, 180, 60, 3, WHITE) end},
        {"a glow", function() layer:bloom(90, 40, 40, 1, WHITE) end},
        {"a frame", function() layer:frame(60, 0, 80, 20, 1, WHITE) end},
        {"an outline",
         function() layer:outline({20, 20, 180, 20, 180, 60}, 2, WHITE) end},
        {"a fan", function() layer:fan({20, 20, 180, 20, 180, 60}, WHITE) end},
    }) do
        local name, fn = drawing[1], drawing[2]
        local t = drew(fn)
        -- Something has to survive, or the check passes on a shape that was
        -- never drawn.
        check(name .. " is held to the line",
              #t > 0 and rightmost(t) <= EDGE + 0.01,
              #t == 0 and "nothing drawn"
                  or string.format("reached %.2f", rightmost(t)))
    end
    layer:unclip()
end

-- --- and a layer nobody has clipped pays nothing ---------------------------
--
-- The world pushes tens of thousands of triangles a frame through these same
-- four functions. The cut is installed by shadowing them on the instance, so
-- an unclipped layer is running exactly the code it ran before there was a
-- scissor rather than asking about one per shape.

do
    check("no scissor means no shadow on the writers",
          rawget(layer, "tri") == nil and rawget(layer, "rect") == nil,
          "a writer is still shadowed")
    layer:clip(EDGE)
    check("clipping shadows all four",
          rawget(layer, "tri") ~= nil and rawget(layer, "tri_fade") ~= nil
              and rawget(layer, "quad") ~= nil and rawget(layer, "rect") ~= nil,
          "one of them was left alone")
    local past = drew(function() layer:rect(140, 0, 40, 20, WHITE) end)
    check("and it is the shadow doing the cutting", #past == 0,
          #past .. " triangles")
    layer:unclip()
    past = drew(function() layer:rect(140, 0, 40, 20, WHITE) end)
    check("letting go of it draws past the line again",
          near(area(past), 800), tostring(area(past)))

    -- A scissor belongs to the frame that set it, so the reset every frame
    -- opens with takes one away whatever the frame did with it.
    layer:clip(EDGE)
    layer:reset()
    past = drew(function() layer:rect(140, 0, 40, 20, WHITE) end)
    check("and a fresh frame starts without one", near(area(past), 800),
          tostring(area(past)))
end

print(fails == 0 and "all clip checks passed"
      or (fails .. " clip checks failed"))
os.exit(fails == 0 and 0 or 1)
