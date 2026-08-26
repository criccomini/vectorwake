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
-- And it stays shut. This used to stand the menu up whenever there was no
-- world, which is how a player who had asked for nothing met a panel for the
-- length of a directory lookup and a handshake. What goes there now is the
-- loader's own picture, held until a room answers; see `ui.waiting`.
eq(menu.open, false, "no world does not open the menu")

-- The landing: a watch nobody deployed from. There is no seat, so the menu
-- keeps its no-hull tree, and the menu is nobody's business but the player's.
state.online = true
state.attract = true
menu.open = false
eq(frame.live(state, net, sim, menu), true, "the stands are a live world")
eq(menu.home, true, "the stands hold no seat")
eq(menu.open, false, "and the menu is not forced over them")

-- Deploying clears the flag, and the same frame reads as a session.
state.attract = false
eq(frame.live(state, net, sim, menu), true, "deployed world")
eq(menu.home, false, "deploying takes the seat")
eq(menu.open, false, "and leaves the menu shut")

-- Losing the room takes the seat back and leaves the menu where it was. The
-- waiting screen is what stands in for the world, and it carries MENU, so
-- nothing here has to open a panel to keep a way out on the screen.
state.online = false
state.attract = true
eq(frame.live(state, net, sim, menu), false, "no room to stand in")
eq(menu.home, true, "and no seat either")
eq(menu.open, false, "still nobody's menu but the player's")
state.attract = nil
state.online = false

state.replay = {}
menu.open = false
eq(frame.live(state, net, sim, menu), true, "replay world")
eq(menu.home, false, "replay keeps the flight screen")
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

-- --- how far along the wait is ---------------------------------------------
--
-- The rail the waiting screen draws under the name. The page's own loader
-- fills it to BOOT while the engine arrives, and this carries it through the
-- three things the client can still be waiting on. See `landing_rail` in
-- ui.lua for what is drawn and client/tools/single_file.py for the half of
-- the rail that runs before there is an engine at all.
local BOOT, FOUND, LINKED = 0.72, 0.82, 0.92

local function near(actual, expected, label)
    if math.abs(actual - expected) > 0.0005 then
        error(string.format("%s: expected %s, got %s", label,
                            tostring(expected), tostring(actual)))
    end
end

local dialing = {vw = 1280, vh = 720}
local dark = {connected = false}
local silent = {answered = false}
local heard = {answered = true}

-- Nothing answered yet, so the rail picks up exactly where the page put it
-- down. A first frame that started lower would be a bar that shrinks at the
-- hand-off, which is the one thing this arrangement exists to prevent.
near(frame.loading(dialing, 0, dark, silent, false), BOOT, "hand-off")

-- And then it creeps, because a directory lookup is two seconds during which
-- nothing else on this screen moves.
local crept = frame.loading(dialing, 1 / 60, dark, silent, false)
if crept <= BOOT then error("a waiting rail has to move: " .. crept) end
if crept >= FOUND then error("and not past the mark it is waiting on") end

-- A long way past its own stage and it still stops short of the next one: the
-- rail may not say the directory has answered before the directory has.
for _ = 1, 600 do
    frame.loading(dialing, 1 / 60, dark, silent, false)
end
if dialing.load_bar >= FOUND then
    error("the creep reached a mark nothing had landed: " .. dialing.load_bar)
end

-- Each answer is a step somebody can see, and each is the floor from there.
near(frame.loading(dialing, 0, dark, heard, false), FOUND, "directory")
near(frame.loading(dialing, 0, {connected = true}, heard, false), LINKED,
     "welcome")

-- Stopped once there is something to say instead. A rail still climbing under
-- "no games are running" is a client that looks like it is still trying.
local held = dialing.load_bar
eq(frame.loading(dialing, 1, {connected = true}, heard, true), held,
   "a stalled wait holds its rail")

-- A session that drops comes back to the band it is actually in. It was left
-- near the top by a room that had answered, and a redial drawn at nine tenths
-- would be a handshake reporting itself nearly done before it was asked for.
local redial = frame.loading(dialing, 0, dark, heard, false)
if redial >= LINKED then
    error("a redial kept the old rail: " .. redial)
end
if redial < FOUND then error("and lost the stage it is still past") end

-- A tab that was in the background comes back with a whole second of dt on
-- it, and one frame may not jump the rail to a mark nothing has reached.
local woken = {vw = 1280, vh = 720}
frame.loading(woken, 0, dark, silent, false)
if frame.loading(woken, 90, dark, silent, false) >= FOUND then
    error("a long frame jumped the rail past its mark")
end

print("frame tests pass")
