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

local callsign = require("arena.callsign")

local M = {}

M.open = true
M.class = 0
M.mode = 1              -- 1 launch, 2 duel, 3 join, 4 browse
M.MODES = 4

-- Who you are and where you are going.
--
-- The name is generated, never typed. A player is flying immediately, a phone
-- never has to raise a keyboard for it, and a console will hand us the
-- platform's own name when we get there. Tapping it draws another.
--
-- The address is still typed, because an address cannot be invented -- but it
-- is the escape hatch rather than the path: ZONES asks a directory what is
-- running and the player picks from a list.
M.name = "pilot"
M.server = "ws://127.0.0.1:9040"
M.focus = nil           -- nil or "server"; the name is not a text field
M.note = nil            -- set by the arena script when a connection fails

local LIMITS = {server = 64}
local SAVE = sys.get_save_file("vectorwake", "pilot")

function M.save_identity()
    pcall(sys.save, SAVE, {name = M.name, server = M.server})
end

-- A call sign has to outlive the tab. Ratings are keyed by who you are, and a
-- player who is somebody new on every reload has no record to build.
function M.load_identity()
    callsign.seed(os.time() + math.floor(os.clock() * 100000))
    local ok, d = pcall(sys.load, SAVE)
    if ok and type(d) == "table" and type(d.name) == "string" and d.name ~= "" then
        M.name = d.name
        if type(d.server) == "string" and d.server ~= "" then M.server = d.server end
    else
        M.name = callsign.generate()
        M.save_identity()
    end
end

function M.reroll()
    M.name = callsign.generate()
    M.save_identity()
end

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
    if M.mode == 4 then return "zones" end
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
        M.focus = (M.focus == nil) and "server" or nil
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
    elseif action == "reroll" then
        M.reroll()
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
