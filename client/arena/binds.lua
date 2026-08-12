-- Where each control actually is, as against where it starts.
--
-- The engine hands `on_input` one action per key, named for the key, and this
-- turns that into the name of the thing the key does. Everything downstream
-- goes on reading `tapped[hash("thrust")]` and knows nothing about bindings,
-- which is the point: a rebound key arrives under the name of its job, so
-- there is one place that has to be right rather than thirty.
--
-- Conflicts swap. A key already spoken for hands its control the key the
-- arriving one is leaving, so the two trade and neither ends up on nothing.
-- Stealing was the other option and it is a trap: a control with no key is
-- unreachable, and the pilot who does it to `players` or `map` has quietly
-- broken a thing they will not connect to what they just did. Swapping cannot
-- produce that state at all, which is worth more than the surprise costs.
--
-- Escape is not in any of this. It is how you leave the page that does the
-- binding, so it stays where it is; see the `fixed` flag in arena/controls.lua.

local controls = require("arena.controls")
local keys = require("arena.keys")

local M = {}

-- control id -> key id, and back. Two tables rather than one and a search,
-- because the reverse is asked once per key on every frame the board is drawn.
M.key_of = {}
M.control_of = {}

-- Hashed action of a key -> hashed action of whatever is on it. Built once per
-- change and read on every keystroke, so it is a table rather than a lookup
-- through the two above.
local routed = {}

-- Defold hands `on_input` a hashed action_id and never the string. Hashing is
-- only available inside the engine, so a plain Lua test can drive this with
-- the identity instead and still exercise the routing.
local hash_fn = _G.hash or function(s) return s end

local function rebuild()
    routed = {}
    for id, key in pairs(M.key_of) do
        local k = keys.bindable(key) and keys.by_id[key]
        if k then routed[hash_fn(k.action)] = hash_fn(id) end
    end
end

-- What this press is for, or nil where the key does nothing.
function M.action(key_action)
    return routed[key_action]
end

function M.reset()
    M.key_of, M.control_of = {}, {}
    for _, c in ipairs(controls) do
        M.key_of[c.id] = c.key
        M.control_of[c.key] = c.id
    end
    rebuild()
end

-- Whether this control's key is the one it started on. What the page needs to
-- know to say a binding has been moved, and what `save` needs so a stock
-- keyboard is stored as nothing at all.
function M.is_default(id)
    for _, c in ipairs(controls) do
        if c.id == id then return M.key_of[id] == c.key end
    end
    return true
end

function M.fixed(id)
    for _, c in ipairs(controls) do
        if c.id == id then return c.fixed == true end
    end
    return false
end

-- Put `id` on `key`. Returns the control that was displaced, if any, so the
-- page can say what happened; nil when the key was free or nothing changed.
--
-- Refuses a key nothing may be bound to and a control that may not move. Both
-- are answered false rather than silently, since the page draws the refusal.
function M.set(id, key)
    if M.fixed(id) then return nil, false end
    -- Bindable, which is not the same as known: the board draws escape, caps,
    -- enter, backspace and ctrl, and this file can write any of their names in
    -- a list. None of them has a trigger for a press to arrive under, so a
    -- control put on one would be a control on a key that never reports.
    if not keys.bindable(key) then return nil, false end
    local was = M.key_of[id]
    if was == key then return nil, false end
    local other = M.control_of[key]
    if other == id then return nil, false end
    if other and M.fixed(other) then return nil, false end

    M.key_of[id] = key
    M.control_of[key] = id
    if other then
        -- The trade. `was` is never nil: every control on the page has a key,
        -- which is the property swapping exists to keep.
        M.key_of[other] = was
        M.control_of[was] = other
    elseif was then
        M.control_of[was] = nil
    end
    rebuild()
    return other, true
end

-- Only what has moved. A pilot who never opens the page stores nothing, and a
-- control this build stops carrying takes its saved key with it rather than
-- leaving a line in the file that nothing reads.
function M.save_table()
    local out = nil
    for _, c in ipairs(controls) do
        if M.key_of[c.id] ~= c.key then
            out = out or {}
            out[c.id] = M.key_of[c.id]
        end
    end
    return out
end

-- Take what was saved, over the defaults, discarding anything this build does
-- not recognise. A key that has left `keys.lua` between two versions is the
-- case that matters: honoured, it would bind a control to a press that can
-- never arrive, and the pilot would have no way to see why.
--
-- Applied through `set`, so a saved file that puts two controls on one key
-- resolves the same way the page would have: the later one wins and the
-- earlier is moved, rather than both claiming a key and one of them being
-- unreachable.
function M.load(saved)
    M.reset()
    if type(saved) ~= "table" then return end
    for _, c in ipairs(controls) do
        local key = saved[c.id]
        if type(key) == "string" and keys.by_id[key] then M.set(c.id, key) end
    end
end

-- The list the pages draw: every control, in the order controls.lua names
-- them, carrying where it is now.
function M.rows()
    local out = {}
    for i, c in ipairs(controls) do
        out[i] = {id = c.id, name = c.name, what = c.what, cat = c.cat,
                  pad = c.pad, pad_name = c.pad_name, fixed = c.fixed,
                  key = M.key_of[c.id],
                  show = keys.show(M.key_of[c.id])}
    end
    return out
end

M.reset()

return M
