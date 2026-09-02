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
eq(menu.adrift, false, "a room on screen")

state.online = false
menu.open = false
eq(frame.live(state, net, sim, menu), false, "offline world")
eq(menu.adrift, true, "and adrift with it")
-- And it stays shut. This used to stand the menu up whenever there was no
-- world, which is how a player who had asked for nothing met a panel for the
-- length of a directory lookup and a handshake. What goes there now is the
-- loader's own picture, held until a room answers; see `ui.waiting`.
eq(menu.open, false, "no world does not open the menu")

-- A watcher: a room on screen that this client holds no seat in. It reads as
-- a room, because that is what it is. There was a flag for it here, which the
-- interface spent on a whole second screen; see decision 159.
state.online = true
menu.open = false
eq(frame.live(state, net, sim, menu), true, "the stands are a live world")
eq(menu.adrift, false, "and a room like any other")
eq(menu.open, false, "and the menu is not forced over them")

-- Losing the room leaves the menu where it was. The loading screen is what
-- stands in for the world, and the menu comes back over the next room in
-- whatever state the player left it.
state.online = false
eq(frame.live(state, net, sim, menu), false, "no room to stand in")
eq(menu.adrift, true, "adrift again")
eq(menu.open, false, "still nobody's menu but the player's")

state.replay = {}
menu.open = false
eq(frame.live(state, net, sim, menu), true, "replay world")
eq(menu.adrift, false, "a film is a room to draw")
state.replay = nil

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
