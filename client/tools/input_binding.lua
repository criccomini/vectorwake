-- Write client/main/game.input_binding from arena/keys.lua.
--
--     lua5.1 client/tools/input_binding.lua > client/main/game.input_binding
--
-- One trigger per bindable key, named for the key rather than for what it
-- does, because what it does is a thing a pilot may change and this file is
-- fixed at build time. See arena/binds.lua for the other half.
--
-- Generated rather than kept by hand, and checked by binds_test, which is the
-- arrangement the rest of this client uses wherever one list of facts has to
-- appear twice.

package.path = "client/?.lua;" .. package.path

local keys = require("arena.keys")

local out = {}
local function trigger(kind, input, action)
    out[#out + 1] = string.format(
        "%s_trigger {\n  input: %s\n  action: \"%s\"\n}", kind, input, action)
end

-- The keys that work the interface rather than the ship. They are fixed
-- because everything that could put them back is reached through them.
trigger("key", "KEY_ESC", "menu")
trigger("key", "KEY_ENTER", "select")
trigger("key", "KEY_BACKSPACE", "backspace")
-- The one key that opens the controls table without being the one bound to
-- it, so a keyboard nobody can read their way around still has a way in.
trigger("key", "KEY_SLASH", "help")
-- Continuum's own gun key, honored only under the keyboard lock. Not
-- bindable: the browser keeps it unless the page is fullscreen, and a control
-- on a key that arrives half the time is worse than one on no key at all.
trigger("key", "KEY_LCTRL", "guns_ctrl")
trigger("key", "KEY_RCTRL", "guns_ctrl")

for _, k in ipairs(keys.list) do
    trigger("key", k.input, k.action)
    if k.alt then trigger("key", k.alt, k.action) end
end

trigger("mouse", "MOUSE_BUTTON_LEFT", "pointer")
trigger("mouse", "MOUSE_BUTTON_RIGHT", "pointer_alt")
trigger("mouse", "MOUSE_WHEEL_UP", "wheel_up")
trigger("mouse", "MOUSE_WHEEL_DOWN", "wheel_down")
trigger("touch", "TOUCH_MULTI", "touch")
trigger("text", "TEXT", "text")

print(table.concat(out, "\n"))
