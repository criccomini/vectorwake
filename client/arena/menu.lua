-- The start screen's state, and nothing else.
--
-- It draws over a game that is already running, which is why there is no
-- separate attract mode: the arena behind this is the real one, stepping the
-- real simulation, and choosing a hull drops you into it. A player who does
-- nothing still sees a fight rather than a title card.
--
-- Selection only. It spawns nothing and steps nothing; the arena script does
-- that when this reports a choice, and arena/ui.lua draws it.

local M = {}

M.open = true
M.class = 0
M.mode = 1              -- 1 launch, 2 duel
M.MODES = 2

-- One keystroke per entry: the arena script latches presses, because a tap
-- can go down and up inside a single frame and never appear in the key state
-- that flight reads. Nothing here does its own edge detection.
--
-- keys: {left, right, up, down, go} as booleans. Returns "play", "duel", or
-- nil, plus whether anything moved, so the caller can click for it.
function M.step(keys)
    if not M.open then return nil, false end
    local moved = false
    if keys.left then M.class = (M.class - 1) % 8 moved = true end
    if keys.right then M.class = (M.class + 1) % 8 moved = true end
    if keys.up then
        M.mode = M.mode == 1 and M.MODES or M.mode - 1
        moved = true
    end
    if keys.down then M.mode = M.mode % M.MODES + 1 moved = true end
    if keys.go then
        M.open = false
        return M.mode == 2 and "duel" or "play", true
    end
    return nil, moved
end

-- A pointer landed on something arena/ui.lua published as clickable.
function M.click(action, value)
    if action == "class" then
        M.class = value
        return nil, true
    elseif action == "go" then
        M.mode = value
        M.open = false
        return value == 2 and "duel" or "play", true
    end
    return nil, false
end

return M
