-- The start screen.
--
-- It draws over a game that is already running, which is why there is no
-- separate attract mode: the arena behind this is the real one, stepping the
-- real simulation, and choosing a hull drops you into it. That also means a
-- player who does nothing still sees a fight rather than a title card.
--
-- Selection state only. It spawns nothing and steps nothing; the arena
-- script does that when this reports a choice.

local M = {}

local INK    = vmath.vector4(0.78, 0.84, 0.94, 1)
local DIM    = vmath.vector4(0.40, 0.48, 0.60, 1)
local ACCENT = vmath.vector4(0.31, 0.84, 1.00, 1)

M.open = true
M.class = 0
M.mode = 1              -- 1 warzone, 2 duel

local MODES = {"ENTER THE WARZONE", "DUEL A BOT"}

local function text(s, x, y, col)
    msg.post("@render:", "draw_text", {
        text = s, position = vmath.vector3(x, y, 0), color = col})
end

-- One keystroke per entry: the arena script latches presses, because a tap
-- can go down and up inside a single frame and never appear in the key state
-- that flight reads. Nothing here does its own edge detection.
--
-- keys: {left, right, up, down, go} as booleans. Returns "play", "duel", or
-- nil.
function M.step(keys)
    if not M.open then return nil end
    if keys.left then M.class = (M.class - 1) % 8 end
    if keys.right then M.class = (M.class + 1) % 8 end
    if keys.up then M.mode = M.mode == 1 and #MODES or M.mode - 1 end
    if keys.down then M.mode = M.mode % #MODES + 1 end
    if keys.go then
        M.open = false
        return M.mode == 2 and "duel" or "play"
    end
    return nil
end

-- names: class names in roster order. hulls: outlines, nose along +y.
function M.draw(w, h, names, hulls, cam_x, cam_y, hw, hh)
    if not M.open then return end

    local cx = w * 0.5
    text("V E C T O R W A K E", cx - 90, h - 90, ACCENT)
    text("a top-down space game", cx - 92, h - 112, DIM)

    -- The roster, with the chosen hull named. Eight names across a narrow
    -- window would wrap into nonsense, so only the selection is spelled out.
    text("HULL", cx - 150, h - 176, DIM)
    text(names[M.class + 1] or "?", cx - 100, h - 176, INK)
    text("< >", cx + 96, h - 176, DIM)

    for i = 1, #MODES do
        local on = (i == M.mode)
        text((on and "> " or "  ") .. MODES[i],
             cx - 150, h - 212 - (i - 1) * 22, on and ACCENT or DIM)
    end

    text("arrows choose    enter starts", cx - 118, h - 292, DIM)
    text("in flight: arrows steer, space guns, shift bombs",
         cx - 186, h - 314, DIM)

    -- The chosen hull, drawn large in world space beside the text so the
    -- silhouette is what picks the ship rather than the name.
    local pts = hulls[M.class + 1]
    if not pts then return end
    -- Left of the text. The player's own ship sits at the camera centre, so
    -- a preview drawn there would overlap it.
    local ox, oy = cam_x - hw * 0.42, cam_y - hh * 0.05
    local S = 2.2
    for i = 1, #pts do
        local p, q = pts[i], pts[i % #pts + 1]
        msg.post("@render:", "draw_line", {
            start_point = vmath.vector3(ox + p[1] * S, oy - p[2] * S, 0),
            end_point = vmath.vector3(ox + q[1] * S, oy - q[2] * S, 0),
            color = ACCENT})
    end
end

return M
