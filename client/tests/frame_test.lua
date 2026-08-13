-- Frame state stays independent of Defold so its clocks and page sampling can
-- be tested without loading the arena script.

package.path = "client/?.lua;" .. package.path

local frame = require("arena.frame")

local function eq(actual, expected, label)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", label,
                            tostring(expected), tostring(actual)))
    end
end

local state = {vw = 1280, vh = 720, density = 2, online = true}
local net = {connected = true, stats = {rx = 120, tx = 50}}
function net.tick(dt) net.ticked = dt end
local sfx = {}
function sfx.frame() sfx.frames = (sfx.frames or 0) + 1 end
function sfx.music_tick(dt) sfx.music = dt end
local menu = {open = false}
local sim = {}
function sim.ship_count() return 2 end

local w, h, density, live = frame.begin(state, 0.25, net, sfx, menu, sim)
eq(w, 1280, "width")
eq(h, 720, "height")
eq(density, 2, "density")
eq(live, true, "live world")
eq(state.clock, 0.25, "wall clock")
eq(net.ticked, 0.25, "transport clock")
eq(sfx.frames, 1, "sound frame")
eq(sfx.music, 0.25, "music clock")
eq(menu.home, false, "live menu state")

state.online = false
menu.open = false
eq(frame.live(state, net, sim, menu), false, "offline world")
eq(menu.home, true, "offline menu state")
eq(menu.open, true, "offline menu stays open")

local page = {}
function page.run(script)
    if string.find(script, "vwLocked", 1, true) then return "1" end
    if string.find(script, "vwInsets", 1, true) then
        return "1 2 3 4 1 720 700 680 740 844 12"
    end
    return ""
end

state.lock_t = 0.6
state.perf_t = 0.6
state.perf_frames = 3
state.rx_was = 20
state.tx_was = 10
local locked = frame.sample(state, 0.5, net, page, false)
eq(locked, true, "keyboard lock")
eq(state.safe_l, 1, "left inset")
eq(state.safe_b, 4, "bottom inset")
eq(state.installed, true, "installed mode")
eq(state.vp_visual, 700, "visual viewport")
eq(state.fps, 4 / 1.1, "frame rate")
eq(state.rx_rate, 100 / 1.1, "receive rate")
eq(state.tx_rate, 40 / 1.1, "send rate")
eq(state.perf_t, 0, "performance window reset")

local hidden = {vw = 0, vh = 720}
eq(frame.begin(hidden, 1, net, sfx, menu, sim), nil,
   "zero-width frame is skipped")
eq(hidden.clock, nil, "skipped frame changes no clock")

print("frame tests pass")
