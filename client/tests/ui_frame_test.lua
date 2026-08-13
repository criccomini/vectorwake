-- The UI frame context owns the mutable drawing surface without requiring the
-- rest of the renderer.

package.path = "client/?.lua;" .. package.path

local ui_frame = require("arena.ui_frame")

local state = {text = {}, n = 7, version = 3}
local layer = {}
function layer.reset() layer.resets = (layer.resets or 0) + 1 end
function layer.flush() layer.flushes = (layer.flushes or 0) + 1 end

local frame = ui_frame.new(state)
frame:safe(1, 2, 3, 4, true)
frame.zones[1] = {key = "old"}
frame:begin(layer, 1280, 720, 2, 12.5)

assert(frame.w == 1280 and frame.h == 720 and frame.scale == 2)
assert(frame.layer == layer and frame.text == state.text)
assert(frame.now == 12.5 and frame.text_count == 0)
assert(#frame.zones == 0 and layer.resets == 1)
assert(frame.safe_l == 1 and frame.safe_r == 2)
assert(frame.safe_t == 3 and frame.safe_b == 4 and frame.installed)
assert(frame:ry(20, 5) == 695)

frame.text_count = 4
frame:finish()
assert(state.n == 4 and state.version == 4 and layer.flushes == 1)

local source = assert(io.open("client/arena/ui.lua")):read("*a")
for _, field in ipairs({"w", "h", "scale", "layer", "text", "menu_up",
                        "text_dim", "case", "now", "safe_l", "safe_r",
                        "safe_t", "safe_b", "installed", "zones"}) do
    assert(not source:match('"[^"\n]*F%.' .. field .. '[^"\n]*"'))
end

print("ui frame tests pass")
