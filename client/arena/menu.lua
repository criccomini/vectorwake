-- The start screen's state, and nothing else.
--
-- It draws over a game that is already running, which is why there is no
-- separate attract mode: the arena behind this is the real one, stepping the
-- real simulation, and choosing a hull drops you into it. A player who does
-- nothing still sees a fight rather than a title card.
--
-- Selection only. It spawns nothing, steps nothing, and opens no socket; the
-- arena script does that when this reports a choice, and arena/ui.lua draws
-- it.

local M = {}

M.open = true
M.class = 0
M.mode = 1              -- 1 launch, 2 duel, 3 join
M.MODES = 3

-- Who you are and where you are going. A published page has no server behind
-- it, so these are editable: whoever runs a zone hands out an address, and
-- the name is what everyone else in that zone sees over your hull.
M.name = "pilot"
M.server = "ws://127.0.0.1:9040"
M.focus = nil           -- nil, "name", or "server"
M.note = nil            -- set by the arena script when a connection fails

local LIMITS = {name = 16, server = 64}

function M.defaults(name, server)
    if name and name ~= "" then M.name = name end
    if server and server ~= "" then M.server = server end
end

-- A printable character arrived while a field had focus.
function M.type(s)
    if not M.open or not M.focus then return false end
    local cur = M[M.focus] or ""
    if #cur >= LIMITS[M.focus] then return true end
    -- Newlines and tabs are not addresses or names, and the engine does
    -- deliver them.
    s = string.gsub(s, "[%c]", "")
    M[M.focus] = cur .. s
    return true
end

function M.backspace()
    if not M.open or not M.focus then return false end
    M[M.focus] = string.sub(M[M.focus] or "", 1, -2)
    return true
end

local function chosen()
    M.open = false
    M.focus = nil
    if M.mode == 2 then return "duel" end
    if M.mode == 3 then return "join" end
    return "play"
end

-- One keystroke per entry: the arena script latches presses, because a tap
-- can go down and up inside a single frame and never appear in the key state
-- that flight reads. Nothing here does its own edge detection.
--
-- keys: {left, right, up, down, go, tab} as booleans. Returns "play",
-- "duel", "join", or nil, plus whether anything moved, so the caller can
-- click for it.
function M.step(keys)
    if not M.open then return nil, false end
    local moved = false

    -- Tab reaches the fields without a pointer. Without it a keyboard-only
    -- player cannot type an address at all, which on a page whose whole
    -- point is joining somebody else's zone is not a small omission.
    if keys.tab then
        M.focus = (M.focus == nil and "name")
            or (M.focus == "name" and "server")
            or nil
        return nil, true
    end

    -- While a field is being typed into, enter commits the field rather than
    -- launching: a player finishing an address and pressing enter means "that
    -- is the address", not "go now, with whatever is in there".
    if M.focus then
        if keys.go then
            M.focus = nil
            return nil, true
        end
        return nil, false
    end

    if keys.left then M.class = (M.class - 1) % 8 moved = true end
    if keys.right then M.class = (M.class + 1) % 8 moved = true end
    if keys.up then
        M.mode = M.mode == 1 and M.MODES or M.mode - 1
        moved = true
    end
    if keys.down then M.mode = M.mode % M.MODES + 1 moved = true end
    if keys.go then return chosen(), true end
    return nil, moved
end

-- A pointer landed on something arena/ui.lua published as clickable.
function M.click(action, value)
    if action == "class" then
        M.class = value
        M.focus = nil
        return nil, true
    elseif action == "field" then
        M.focus = value
        return nil, true
    elseif action == "go" then
        M.focus = nil
        M.mode = value
        return chosen(), true
    end
    -- A tap anywhere else drops the caret, so a field does not swallow the
    -- keyboard forever on a device with no escape key.
    M.focus = nil
    return nil, false
end

return M
