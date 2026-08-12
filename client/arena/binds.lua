-- Where each control actually is, as against where it starts.
--
-- A binding is a chord: one or more keys held together, triggered by the last
-- of them. Most are one key. Mines are Shift and the bomb key, which is the
-- original's own chord and the reason this file counts rather than compares.
--
-- The engine hands `on_input` one action per key, named for the key, and this
-- turns that into the name of the thing the key does. Everything downstream
-- goes on reading `tapped[hash("thrust")]` and knows nothing about bindings,
-- which is the point: a rebound key arrives under the name of its job, so
-- there is one place that has to be right rather than thirty.
--
-- Two controls may share a trigger as long as their modifiers differ, and that
-- is what makes Shift+Tab a mine while Tab alone is a bomb. A press picks the
-- most specific chord whose modifiers are all down, so adding a modifier can
-- only ever take presses away from the barer binding, never the reverse.
--
-- Identical chords swap. The one already spoken for hands its control the
-- chord the arriving one is leaving, so the two trade and neither ends up on
-- nothing. Stealing was the other option and it is a trap: a control with no
-- chord is unreachable, and the pilot who does that to `players` or `map` has
-- quietly broken a thing they will not connect to what they just did. Swapping
-- cannot produce that state at all, which is worth more than the surprise
-- costs.
--
-- Escape is not in any of this. It is how you leave the page that does the
-- binding, so it stays where it is; see the `fixed` flag in arena/controls.lua.

local controls = require("arena.controls")
local keys = require("arena.keys")

local M = {}

-- control id -> the keys it is on, and back by chord. Two tables rather than
-- one and a search, because the reverse is asked once per key on every frame
-- the board is drawn.
M.chord_of = {}
M.control_of = {}

-- Trigger key id -> the chords that fire on it, longest first, so the first
-- whose modifiers are all down is the answer. Built once per change and walked
-- on every keystroke.
local by_trigger = {}

-- Defold hands `on_input` a hashed action_id and never the string. Hashing is
-- only available inside the engine, so a plain Lua test can drive this with
-- the identity instead and still exercise the routing.
local hash_fn = _G.hash or function(s) return s end

local function copy(list)
    local out = {}
    for i, v in ipairs(list) do out[i] = v end
    return out
end

-- What a chord is called, once, so two orders of the same keys are one binding
-- rather than two. Held keys first, in the catalog's order, then everything
-- else in the order it was pressed: Shift then Tab and Tab then Shift are the
-- same thing to the hand that does them.
local function normalize(chord)
    local out, seen = {}, {}
    for _, k in ipairs(keys.list) do
        for _, id in ipairs(chord) do
            if id == k.id and keys.MODS[id] and not seen[id] then
                seen[id] = true
                out[#out + 1] = id
            end
        end
    end
    for _, id in ipairs(chord) do
        if not keys.MODS[id] and not seen[id] then
            seen[id] = true
            out[#out + 1] = id
        end
    end
    return out
end

local function sign(chord)
    return table.concat(chord, "+")
end

local function rebuild()
    by_trigger = {}
    for id, chord in pairs(M.chord_of) do
        local trigger = chord[#chord]
        if keys.bindable(trigger) then
            local mods = {}
            for i = 1, #chord - 1 do mods[i] = chord[i] end
            local list = by_trigger[trigger] or {}
            list[#list + 1] = {id = hash_fn(id), mods = mods, n = #mods}
            by_trigger[trigger] = list
        end
    end
    for _, list in pairs(by_trigger) do
        table.sort(list, function(a, b) return a.n > b.n end)
    end
end

-- What this press is for, given what else is down, or nil where the key does
-- nothing. `down` answers whether a key id is currently held.
--
-- Longest chord first, so Shift+Tab beats Tab whenever Shift is down. It has
-- to be that way round: the barer binding is what a hand falls back to, and a
-- modifier that failed to win would be a key that did nothing anybody could
-- see.
function M.match(trigger, down)
    for _, c in ipairs(by_trigger[trigger] or {}) do
        local ok = true
        for _, m in ipairs(c.mods) do
            if not down(m) then ok = false break end
        end
        if ok then return c.id end
    end
    return nil
end

-- The same question in the engine's own terms: a hashed key action, and the
-- table of what is held, by hashed action. What `arena.script` calls.
local action_of = {}
for _, k in ipairs(keys.list) do action_of[hash_fn(k.action)] = k.id end

function M.on_press(key_action, held)
    local trigger = action_of[key_action]
    if not trigger then return nil end
    return M.match(trigger, function(id)
        local k = keys.by_id[id]
        return k ~= nil and held[hash_fn(k.action)] ~= nil
    end)
end

function M.reset()
    M.chord_of, M.control_of = {}, {}
    for _, c in ipairs(controls) do
        local chord = normalize(c.keys)
        M.chord_of[c.id] = chord
        M.control_of[sign(chord)] = c.id
    end
    rebuild()
end

local function same(a, b)
    return a ~= nil and b ~= nil and sign(a) == sign(b)
end

-- Whether this control's chord is the one it started on. What the page needs
-- to say a binding has moved, and what `save` needs so a stock keyboard is
-- stored as nothing at all.
function M.is_default(id)
    for _, c in ipairs(controls) do
        if c.id == id then return same(M.chord_of[id], normalize(c.keys)) end
    end
    return true
end

function M.fixed(id)
    for _, c in ipairs(controls) do
        if c.id == id then return c.fixed == true end
    end
    return false
end

-- Put `id` on `chord`. Returns the control that was displaced, if any, so the
-- page can say what happened; nil when the chord was free or nothing changed.
--
-- Refuses a chord with a key nothing may be bound to in it, and a control that
-- may not move. Both are answered false rather than silently, since the page
-- draws the refusal.
function M.set(id, chord)
    if M.fixed(id) then return nil, false end
    if type(chord) ~= "table" or #chord == 0 then return nil, false end
    -- Bindable, which is not the same as known: the board draws escape, caps,
    -- enter, backspace and ctrl, and this file can write any of their names in
    -- a list. None of them has a trigger for a press to arrive under, so a
    -- control put on one would be a control on a key that never reports.
    for _, key in ipairs(chord) do
        if not keys.bindable(key) then return nil, false end
    end
    chord = normalize(chord)
    local was = M.chord_of[id]
    if same(was, chord) then return nil, false end
    local other = M.control_of[sign(chord)]
    if other == id then return nil, false end
    if other and M.fixed(other) then return nil, false end

    M.chord_of[id] = chord
    M.control_of[sign(chord)] = id
    if other then
        -- The trade. `was` is never nil: every control on the page has a
        -- chord, which is the property swapping exists to keep.
        M.chord_of[other] = was
        M.control_of[sign(was)] = other
    elseif was then
        M.control_of[sign(was)] = nil
    end
    rebuild()
    return other, true
end

-- Only what has moved. A pilot who never opens the page stores nothing, and a
-- control this build stops carrying takes its chord with it rather than
-- leaving a line in the file that nothing reads.
function M.save_table()
    local out = nil
    for _, c in ipairs(controls) do
        if not M.is_default(c.id) then
            out = out or {}
            out[c.id] = copy(M.chord_of[c.id])
        end
    end
    return out
end

-- Take what was saved, over the defaults, discarding anything this build does
-- not recognize. A key that has left `keys.lua` between two versions is the
-- case that matters: honored, it would bind a control to a press that can
-- never arrive, and the pilot would have no way to see why.
--
-- Applied through `set`, so a saved file that puts two controls on one chord
-- resolves the same way the page would have: the later one wins and the
-- earlier is moved, rather than both claiming it and one being unreachable.
function M.load(saved)
    M.reset()
    if type(saved) ~= "table" then return end
    for _, c in ipairs(controls) do
        local chord = saved[c.id]
        -- A bare key, from a file written before chords existed, is a chord of
        -- one. Cheaper to read than to migrate, and it is the only shape the
        -- older file could hold.
        if type(chord) == "string" then chord = {chord} end
        if type(chord) == "table" then M.set(c.id, chord) end
    end
end

-- The list the pages draw: every control, in the order controls.lua names
-- them, carrying where it is now.
function M.rows()
    local out = {}
    for i, c in ipairs(controls) do
        local chord = M.chord_of[c.id]
        out[i] = {id = c.id, name = c.name, what = c.what, cat = c.cat,
                  pad = c.pad, pad_name = c.pad_name, fixed = c.fixed,
                  keys = chord, show = keys.chord(chord)}
    end
    return out
end

M.reset()

return M
