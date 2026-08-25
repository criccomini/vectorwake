-- Every key a control may be bound to.
--
-- The board drawn on the controls page and this list are the same set, and a
-- test says so: a key the picture draws and this does not is a key you can
-- point at and cannot use, and one this carries that the picture leaves out is
-- a key nobody can find. `label` is what the board writes on it and `show` is
-- what a list writes. They differ in one place: the arrows are drawn as
-- triangles and written as glyphs.
--
-- Both are the unshifted legend, always. A binding is a physical key and shift
-- is a key in its own right, so a board writing `~` on the backquote was
-- naming a character nothing here binds: the chip beside it said the other
-- one, and the two disagreed about the same key. Nor do the legends swap while
-- shift is held down. Holding shift is how a chord is typed, and relabeling
-- the board underneath a hand doing that renames every key at the one moment
-- the page is being read for which key is which.
--
-- `input` is the engine's own name for it, and `action` is the name it arrives
-- under. One action per key, rather than one per thing a key does, is the
-- whole of what makes rebinding possible: `arena.script` looks up what the key
-- is for and latches the press under that instead. See arena/binds.lua.
--
-- Five keys the board draws are in `fixed` rather than here, and every one of
-- them is a key something else on the page is reached by. Escape leaves any
-- card, page or table; enter chooses; backspace rubs out. Caps does nothing
-- anywhere. Ctrl is the original's gun key and stays wired to guns alone,
-- because the browser only surrenders it in fullscreen: a control on a key
-- that arrives half the time is worse than one on no key at all, which is why
-- the board draws it at half light.

local M = {}

local function K(id, label, show, input, alt)
    return {id = id, label = label, show = show, input = input, alt = alt,
            action = "k_" .. id}
end

-- In the board's own order, which is the order a test walks them in.
M.list = {
    -- KEY_TILDE beside KEY_BACKQUOTE because a browser reports the shifted
    -- key as its own code and the same physical key has to answer either way.
    -- Which is the reason the legend is the unshifted one: shift and this key
    -- are a chord on the backquote, not a press of something else.
    K("tick", "`", "`", "KEY_BACKQUOTE", "KEY_TILDE"),
    K("1", "1", "1", "KEY_1"), K("2", "2", "2", "KEY_2"),
    K("3", "3", "3", "KEY_3"), K("4", "4", "4", "KEY_4"),
    K("5", "5", "5", "KEY_5"), K("6", "6", "6", "KEY_6"),
    K("7", "7", "7", "KEY_7"), K("8", "8", "8", "KEY_8"),
    K("9", "9", "9", "KEY_9"), K("0", "0", "0", "KEY_0"),
    K("minus", "-", "-", "KEY_MINUS"),
    K("equals", "=", "=", "KEY_EQUALS"),

    K("tab", "tab", "Tab", "KEY_TAB"),
    K("q", "Q", "Q", "KEY_Q"), K("w", "W", "W", "KEY_W"),
    K("e", "E", "E", "KEY_E"), K("r", "R", "R", "KEY_R"),
    K("t", "T", "T", "KEY_T"), K("y", "Y", "Y", "KEY_Y"),
    K("u", "U", "U", "KEY_U"), K("i", "I", "I", "KEY_I"),
    K("o", "O", "O", "KEY_O"), K("p", "P", "P", "KEY_P"),
    K("lbracket", "[", "[", "KEY_LBRACKET"),
    K("rbracket", "]", "]", "KEY_RBRACKET"),
    K("backslash", "\\", "\\", "KEY_BACKSLASH"),

    K("a", "A", "A", "KEY_A"), K("s", "S", "S", "KEY_S"),
    K("d", "D", "D", "KEY_D"), K("f", "F", "F", "KEY_F"),
    K("g", "G", "G", "KEY_G"), K("h", "H", "H", "KEY_H"),
    K("j", "J", "J", "KEY_J"), K("k", "K", "K", "KEY_K"),
    K("l", "L", "L", "KEY_L"),
    K("semicolon", ";", ";", "KEY_SEMICOLON"),
    K("quote", "'", "'", "KEY_QUOTE"),

    -- Either shift, one control, since a chord is held with whichever hand is
    -- free and which one that is depends on where the trigger has been put.
    K("shift", "shift", "Shift", "KEY_LSHIFT", "KEY_RSHIFT"),
    K("z", "Z", "Z", "KEY_Z"), K("x", "X", "X", "KEY_X"),
    K("c", "C", "C", "KEY_C"), K("v", "V", "V", "KEY_V"),
    K("b", "B", "B", "KEY_B"), K("n", "N", "N", "KEY_N"),
    K("m", "M", "M", "KEY_M"),
    K("comma", ",", ",", "KEY_COMMA"),
    K("period", ".", ".", "KEY_PERIOD"),
    K("slash", "/", "/", "KEY_SLASH"),

    K("space", "space", "Space", "KEY_SPACE"),

    -- The two keys this game uses from the navigation block. They sit above
    -- the arrows on the drawn board, in the same place they sit on a full
    -- keyboard.
    K("pageup", "pgup", "PgUp", "KEY_PAGEUP"),
    K("pagedown", "pgdn", "PgDn", "KEY_PAGEDOWN"),

    -- The arrow cluster. `label` is nil because the board draws a triangle
    -- rather than a word on each of them.
    K("up", nil, "\226\134\145", "KEY_UP"),
    K("left", nil, "\226\134\144", "KEY_LEFT"),
    K("down", nil, "\226\134\147", "KEY_DOWN"),
    K("right", nil, "\226\134\146", "KEY_RIGHT"),
}

-- Drawn on the board, named in a list, and never bound to anything. They are
-- here so the rest of the client can ask what to write on them without a
-- second table of key names, and out of `M.list` so nothing offers them. No
-- `action`, because there is no trigger for one to arrive under: a control put
-- on one of these would be a control on a press that never comes.
local function F(id, label, show)
    return {id = id, label = label, show = show}
end

M.fixed = {
    F("esc", "esc", "Esc"),
    F("bksp", "bksp", "Backspace"),
    F("caps", "caps", "Caps"),
    F("enter", "enter", "Enter"),
    F("ctrl", "ctrl", "Ctrl"),
}

M.by_id = {}
-- What the board writes on a key, back to the key. The picture holds labels
-- and has to be able to ask what it is drawing.
M.by_label = {}
for _, set in ipairs({M.list, M.fixed}) do
    for _, k in ipairs(set) do
        M.by_id[k.id] = k
        if k.label then M.by_label[k.label] = k end
    end
end

function M.show(id)
    local k = M.by_id[id]
    return k and k.show or "none"
end

-- Which keys are held rather than pressed, for the one purpose that has to
-- know: putting a chord in an order. Shift and Tab and Tab and Shift are the
-- same thing to the hand that does them, so they are made the same thing here
-- rather than two bindings a pilot has to tell apart. Shift is the only one on
-- the board that is both a modifier and a key anything may be bound to; ctrl
-- is a modifier the browser keeps.
M.MODS = {shift = true}

-- How a chord is written: the keys it is made of, joined. Not a sentence and
-- not a picture, because it is a reading off the machine and the plus is what
-- every machine in the world writes between two keys held together.
function M.chord(list)
    if not list or #list == 0 then return "none" end
    local out = {}
    for i, id in ipairs(list) do out[i] = M.show(id) end
    return table.concat(out, "+")
end

-- Whether anything may be put on this key. Membership of `list` and nothing
-- else: `fixed` carries the same shape so the page can write a word on those
-- keys, and asking for an `action` would be asking the wrong question the day
-- one of them grows a trigger for some other reason.
function M.bindable(id)
    local k = M.by_id[id]
    if not k then return false end
    for _, b in ipairs(M.list) do
        if b == k then return true end
    end
    return false
end

return M
