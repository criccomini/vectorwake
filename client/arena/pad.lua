-- A gamepad: the third hand, beside the keyboard and the thumb.
--
-- The browser's Gamepad API reaches the engine as GAMEPAD_* inputs on a
-- standard layout, two sticks, a d-pad, four face buttons, two shoulders and
-- two triggers. This file says what each of them does, in the same terms the
-- keyboard and the touch pads already use: a control id from
-- arena/controls.lua, latched by arena.script under the control's own name
-- so nothing downstream knows which hand pressed it.
--
-- The layout is fixed. Keys can be moved because a keyboard has sixty of
-- them and a pilot's hand may sit anywhere on it; a pad has one place for a
-- thumb and one for each finger, and the layout below is where every other
-- game of this shape puts the same things. The controls page writes the pad's
-- button beside the key on every row, so what is fixed is at least written
-- down where the keys are.
--
-- Flying is two things on the pad, and a pilot uses whichever they reach for.
-- The d-pad is the keyboard's arrows: left and right are the rudder, up is
-- the engine, down backs up. The left stick points where the nose should go,
-- the way the thumb does on glass, and the engine lights once the push is
-- committed and the nose is roughly there. Both go through the same course
-- arithmetic in arena/course.lua. The stick sets no reverse stance, because
-- the pad has a key for backing up: hold down on the d-pad and point the
-- stick at what you are backing away from, which is the one thing the thumb
-- on glass could never do.
--
-- Guns are on the right trigger and bombs on the left, since a trigger is the
-- finger a shooter rests on. The bottom face button fires too and the left
-- one bombs, for a hand that flies on the d-pad with the right thumb free.
-- The shoulders spend the two charges, the top face button fans the gun.
-- Start is the menu key and Back is the map, which is what those two buttons
-- are for on every pad they appear on. The right face button opens the
-- players sheet while flying and is the way back while the column is up,
-- which is the pad's own convention and the reason `on_press` has to be told
-- whether the column is up.
--
-- The face buttons are named A, B, X, Y after their positions on the layout
-- the browser reports, which is the Xbox letters. A PlayStation pad wears
-- cross, circle, square and triangle in the same four places.
--
-- Chrome and Safari report no pad at all until a button on it is pressed,
-- so a pad that is plugged in and untouched does not exist yet as far as this
-- file can tell. `seen` is the first press, and it is what the controls page
-- reads to start writing the pad's buttons beside the keys.

local course = require("arena.course")

local M = {}

-- Defold hands `on_input` a hashed action_id and never the string. Hashing is
-- only available inside the engine, so a plain Lua test can drive this with
-- the identity instead and still exercise the routing.
local hash_fn = _G.hash or function(s) return s end

-- Every input a standard pad has that this game reads, as the engine names
-- it and as a pilot reads it. `action` is the name a press arrives under,
-- one per input rather than one per thing an input does, so the binding file
-- is fixed at build time and what a button does is not.
local function P(id, input, show)
    return {id = id, input = "GAMEPAD_" .. input, show = show,
            action = "pad_" .. id}
end

M.list = {
    P("lstick_left", "LSTICK_LEFT", "stick"),
    P("lstick_right", "LSTICK_RIGHT", "stick"),
    P("lstick_up", "LSTICK_UP", "stick"),
    P("lstick_down", "LSTICK_DOWN", "stick"),
    P("lpad_left", "LPAD_LEFT", "pad \226\134\144"),
    P("lpad_right", "LPAD_RIGHT", "pad \226\134\146"),
    P("lpad_up", "LPAD_UP", "pad \226\134\145"),
    P("lpad_down", "LPAD_DOWN", "pad \226\134\147"),
    -- Fingers before thumbs, so a control on both is written trigger first.
    P("ltrigger", "LTRIGGER", "LT"),
    P("rtrigger", "RTRIGGER", "RT"),
    P("lshoulder", "LSHOULDER", "LB"),
    P("rshoulder", "RSHOULDER", "RB"),
    P("rpad_down", "RPAD_DOWN", "A"),
    P("rpad_right", "RPAD_RIGHT", "B"),
    P("rpad_left", "RPAD_LEFT", "X"),
    P("rpad_up", "RPAD_UP", "Y"),
    P("start", "START", "Start"),
    P("back", "BACK", "Back"),
    -- Not buttons. The engine raises these when a pad arrives or leaves, and
    -- they carry no press.
    P("connected", "CONNECTED"),
    P("disconnected", "DISCONNECTED"),
}

M.by_id = {}
for _, p in ipairs(M.list) do M.by_id[p.id] = p end

-- What each input is while flying, by control id. The stick is not here: it
-- is a value read every frame by `bits` rather than a press latched under a
-- control.
M.FLIGHT = {
    lpad_left = "turn_left",
    lpad_right = "turn_right",
    lpad_up = "thrust",
    lpad_down = "reverse",
    rtrigger = "guns",
    rpad_down = "guns",
    ltrigger = "bombs",
    rpad_left = "bombs",
    rshoulder = "charge_1",
    lshoulder = "charge_2",
    rpad_up = "multi",
    rpad_right = "details",
    back = "map",
    start = "menu",
}

-- And while the column is up, when the pad walks it. The menu takes five
-- inputs, and these are the five under nav names of their own rather than
-- under the arrow keys', so that a control waiting for a key chord on the
-- controls page cannot read a d-pad press as the up arrow. `menu` is the
-- control, not a nav name: it is the way back out of anything and the frame
-- loop already reads it as such.
M.MENU = {
    lpad_left = "nav_left",
    lpad_right = "nav_right",
    lpad_up = "nav_up",
    lpad_down = "nav_down",
    lstick_left = "nav_left",
    lstick_right = "nav_right",
    lstick_up = "nav_up",
    lstick_down = "nav_down",
    rpad_down = "nav_go",
    rpad_right = "menu",
    start = "menu",
}

-- The nav names, hashed, for the frame loop to read beside the arrow keys.
M.NAV = {
    left = hash_fn("nav_left"),
    right = hash_fn("nav_right"),
    up = hash_fn("nav_up"),
    down = hash_fn("nav_down"),
    go = hash_fn("nav_go"),
}

-- Hashed action -> input id, and input id -> hashed control, built once.
local id_of = {}
for _, p in ipairs(M.list) do id_of[hash_fn(p.action)] = p.id end
local flight_of, menu_of = {}, {}
for id, control in pairs(M.FLIGHT) do flight_of[id] = hash_fn(control) end
for id, control in pairs(M.MENU) do menu_of[id] = hash_fn(control) end

-- Whether a pad has ever reported, which pads are here now, and whether the
-- one that spoke last was on a layout the engine knows.
M.seen = false
M.pads = {}
M.unknown = false

-- The left stick, as the engine last reported it: one value per direction,
-- 0 to 1, and whether that direction reported since the frame began. A
-- direction the engine has stopped sending is a direction at rest, and
-- `begin_frame` is what makes it read so, since the engine's own release is
-- only raised for a push that went past its press threshold and a thumb
-- easing a stick halfway out and back never crosses it.
local axis = {lstick_left = 0, lstick_right = 0, lstick_up = 0, lstick_down = 0}
local alive = {}

-- Below this much push the stick asks for nothing; past `FULL` the engine
-- lights. The engine's own dead zone on the web layout is 0.2, so anything
-- that reaches here is already a push, and `DEAD` is a little above it so a
-- stick resting off center by a hair does not hold the rudder.
local DEAD = 0.25
local FULL = 0.7

-- What arrived, whichever kind of pad action it is. Returns true for a pad
-- action, so the caller knows to route the press through `on_press` rather
-- than the keyboard's bindings; false for anything else.
function M.on_action(action_id, action)
    local id = id_of[action_id]
    if not id then return false end
    M.seen = true
    if action.gamepad ~= nil then
        if id == "disconnected" then
            M.pads[action.gamepad] = nil
        else
            M.pads[action.gamepad] = true
        end
    end
    if action.gamepad_unknown ~= nil then M.unknown = action.gamepad_unknown end
    if axis[id] then
        axis[id] = action.value or (action.released and 0 or 1)
        alive[id] = true
    end
    return true
end

-- Which control this press is, given whether the column is up. Nil for an
-- input that is nothing in this state, and for anything that is not a pad
-- action at all.
function M.on_press(action_id, menu_open)
    local id = id_of[action_id]
    if not id then return nil end
    if menu_open then
        return menu_of[id] or flight_of[id]
    end
    return flight_of[id]
end

-- Called once at the top of every frame, after the engine has delivered the
-- frame's input and before anything reads the stick. A direction that did
-- not report is at rest.
function M.begin_frame()
    for id in pairs(axis) do
        if not alive[id] then axis[id] = 0 end
        alive[id] = false
    end
end

local function push()
    return axis.lstick_right - axis.lstick_left,
           axis.lstick_up - axis.lstick_down
end

-- Whether the stick is naming a course, in which case it owns the rudder and
-- the d-pad's turn keys are ignored, the same rule the thumb has.
function M.steering()
    local dx, dy = push()
    return dx * dx + dy * dy >= DEAD * DEAD
end

-- The bits the stick holds this frame, given where the ship is pointing. A
-- list rather than a bitfield, for the same reason touch.bits is.
function M.bits(heading)
    local dx, dy = push()
    return course.bits(dx, dy, DEAD, FULL, heading, false)
end

function M.count()
    local n = 0
    for _ in pairs(M.pads) do n = n + 1 end
    return n
end

-- The pad's buttons for a control, as a pilot reads them, or nil for a
-- control the pad has no button for. In the list's order, so the trigger
-- comes before the face button it doubles.
function M.show(control)
    local out = {}
    for _, p in ipairs(M.list) do
        if M.FLIGHT[p.id] == control and p.show then
            out[#out + 1] = p.show
        end
    end
    if #out == 0 then return nil end
    return table.concat(out, ", ")
end

-- A row's key column, with the pad's buttons after it once a pad has spoken.
-- What the controls page and the table under H both write, so the two cannot
-- disagree about the same button.
function M.label(row)
    local buttons = M.seen and M.show(row.id)
    if not buttons then return row.show end
    return row.show .. " / " .. buttons
end

return M
