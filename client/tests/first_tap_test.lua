-- The first tap of a session, on glass.
--
--     lua5.1 client/tests/first_tap_test.lua
--
-- Defold raises a mouse action for every touch as well as the touch itself.
-- `touch.used` is what keeps that echo out of the interface, and it cannot
-- keep out the first one: both halves of a tap arrive in the same frame, the
-- mouse half is handed over first, and until a touch has been reported the
-- echo is indistinguishable from a click. So the first thing anybody pressed
-- was pressed twice. On a landing stop, which is a toggle, that opened a panel
-- and shut it again inside one frame: the button lit, nothing opened, and the
-- tap after it worked because `touch.used` was set by then.
--
-- Once a session, on the first control a new player finds.
--
-- `arena.script` is a Defold script and cannot be required here, so this reads
-- `on_input` out of it and runs it against stubbed modules, which is what
-- landing_test does with `land_act` for the same reason. What is checked is
-- how many presses a tap makes, not how the rule is spelled.

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

local f = assert(io.open("client/arena/arena.script"))
local src = f:read("*a")
f:close()

local body = src:match(
    "\nfunction on_input%(self, action_id, action%)\n(.-)\nend\n")
check("the arena has an input handler to run", body ~= nil)
if not body then
    print(fails .. " failed")
    os.exit(1)
end

-- The zone stop, as the interface publishes it: one box, one action, and
-- `land_act` is what a press on it reaches.
local STOP = {x = 0, y = 0, w = 300, h = 44, action = "land_zone"}

-- A session, fresh: nothing has touched the screen yet, and the stop is under
-- wherever the tap lands. `forgiving` is the near miss, where a fingertip
-- reaches the box and a mouse pointer does not: `ui.pick` answers the box for
-- a finger alone, which is what the real one does inside the touch floor.
local function session(forgiving)
    local made, taken = {}, nil
    local env
    env = {
        hash = function(s) return s end,
        ui = {
            hits = {STOP},
            pick = function(_, _, finger)
                if forgiving and not finger then return nil end
                return STOP
            end,
        },
        touch = {
            used = false,
            note_used = function() env.touch.used = true end,
            release = function() end,
            on_touch = function(_, _, _, _, claimed) taken = claimed end,
        },
        menu = {open = false, ask = false},
        net = {watching = false},
        sfx = {ui = function() end},
        binds = {on_press = function() return nil end},
        held = {}, tapped = {}, owner = {}, lifted = {},
        -- The landing's own handler. Whether it recognized the action is all
        -- the press path reads back; the count is the question here.
        land_act = function(_, action, value)
            made[#made + 1] = {action = action, value = value}
            return true
        end,
        -- Nothing under the tap is a list, a page or the in-match column, so
        -- no finger is taken as a drag.
        in_list = function() return nil end,
        in_page = function() return false end,
        in_column = function() return false end,
    }
    setmetatable(env, {__index = _G})
    local chunk = assert(loadstring(
        "return function(self, action_id, action)\n" .. body .. "\nend",
        "on_input"))
    setfenv(chunk, env)
    return {
        env = env,
        made = made,
        on_input = chunk(),
        self = {vw = 390, vh = 844, density = 3, clock = 0},
        -- What the touch layer was handed: the fingers the interface took
        -- before the stick and the pads were offered the rest.
        claimed = function() return taken end,
        -- The frame boundary, which is `update` clearing its latches.
        frame = function() env.pointer_took = nil end,
    }
end

local function mouse(s, x, y)
    s.on_input(s.self, "pointer", {pressed = true, screen_x = x, screen_y = y})
end

local function finger(s, id, x, y)
    s.on_input(s.self, "touch",
               {touch = {{id = id, pressed = true, screen_x = x, screen_y = y}}})
end

-- --- one tap is one press ---------------------------------------------------

do
    local s = session(false)
    mouse(s, 100, 600)
    finger(s, 7, 100, 600)
    check("the first tap presses the stop once", #s.made == 1,
          #s.made .. " presses, so a toggle opens and shuts in one frame")
    check("and it is the stop that was tapped",
          s.made[1] and s.made[1].action == "land_zone")
    local taken = s.claimed()
    check("and the finger is taken, so the stick is not offered it",
          taken ~= nil and taken[7] == true)
end

-- The same tap where the fingertip reaches the box and a pointer would have
-- missed it. The echo presses nothing, so the touch behind it is the press,
-- and the near miss the touch floor exists for still lands.
do
    local s = session(true)
    mouse(s, 100, 600)
    finger(s, 7, 100, 600)
    check("a near miss still presses once", #s.made == 1,
          #s.made .. " presses")
    local taken = s.claimed()
    check("and that finger is taken too", taken ~= nil and taken[7] == true)
end

-- Every tap after the first, which is the path that always worked: the mouse
-- action is gated out by `touch.used` and the touch is the only press.
do
    local s = session(false)
    mouse(s, 100, 600)
    finger(s, 7, 100, 600)
    s.frame()
    mouse(s, 100, 600)
    finger(s, 8, 100, 600)
    check("the tap after it presses once as well", #s.made == 2,
          #s.made .. " presses over two taps")
end

-- A hand on a real mouse, which is the case the echo must not be mistaken
-- for: nothing reports a touch, and every click is a press.
do
    local s = session(false)
    mouse(s, 100, 600)
    s.frame()
    mouse(s, 100, 600)
    s.frame()
    check("a mouse clicking twice presses twice", #s.made == 2,
          #s.made .. " presses over two clicks")
    check("and leaves no press lying around for a later tap",
          s.env.pointer_took == nil)
end

-- Two fingers going down in one frame are two presses. The echo is one tap's
-- worth and is spent by the first of them, so the second is its own.
do
    local s = session(false)
    mouse(s, 100, 600)
    s.on_input(s.self, "touch", {touch = {
        {id = 1, pressed = true, screen_x = 100, screen_y = 600},
        {id = 2, pressed = true, screen_x = 100, screen_y = 500},
    }})
    check("a second finger in the same frame is a press of its own",
          #s.made == 1 + 1, #s.made .. " presses from an echo and two fingers")
    local taken = s.claimed()
    check("and both fingers are taken",
          taken ~= nil and taken[1] == true and taken[2] == true)
end

print(fails == 0 and "all first tap checks passed"
      or (fails .. " first tap checks failed"))
os.exit(fails == 0 and 0 or 1)
