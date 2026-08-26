-- Frame-level state that does not belong to flight, drawing, or menus.

local link_quality = require("arena.link_quality")

local M = {}

-- Recompute whether the connection has a world ready to draw. Call this again
-- after input handling because a menu action can join or leave during a frame.
--
-- A watch that nobody deployed from is live to draw and holds no seat, so the
-- menu keeps its no-hull tree. That is the landing: the client opens in the
-- stands of a real room, and pressing play is what turns the connection into a
-- session. It clears the flag itself.
--
-- Nothing here opens the menu any more. It used to stand itself up whenever
-- there was no seat, and later whenever there was no room, so a player who had
-- asked for nothing met a panel for as long as a directory and a handshake
-- took. With no room the client draws the loader's own picture instead and
-- keeps MENU in the corner, so the menu is only ever open because somebody
-- opened it. See `ui.waiting`.
function M.live(self, net, sim, menu)
    local live = (self.replay ~= nil or (self.online and net.connected))
        and sim.ship_count() > 0
    menu.home = not live or self.attract == true
    return live
end

-- Start the clocks that continue whether a zone is live or not. Multiple
-- returns keep the hot path allocation-free.
function M.begin(self, dt, net, sfx, menu, sim)
    local w, h = self.vw or 0, self.vh or 0
    if w == 0 or h == 0 then return nil end

    self.clock = (self.clock or 0) + dt
    net.tick(dt)
    sfx.frame()
    sfx.music_tick(dt)

    return w, h, self.density or 1, M.live(self, net, sim, menu)
end

local function poll_browser(self, dt, html5, locked)
    self.lock_t = (self.lock_t or 1) + dt
    if self.lock_t < 1 then return locked end
    self.lock_t = 0
    if not html5 then return locked end

    local ok, result = pcall(html5.run, "window.vwLocked and '1' or ''")
    locked = ok and result == "1"

    local insets_ok, insets = pcall(html5.run, "window.vwInsets || ''")
    if not insets_ok or not insets or insets == "" then return locked end

    local left, right, top, bottom, app, layout, visual, inner, outer, screen, screen_y =
        string.match(insets,
        "^([%d%.]+) ([%d%.]+) ([%d%.]+) ([%d%.]+) ([%d%.]+)"
        .. " ([%d%.%-]+) ([%d%.%-]+) ([%d%.%-]+) ([%d%.%-]+)"
        .. " ([%d%.%-]+) ([%d%.%-]+)")
    self.safe_l = tonumber(left) or 0
    self.safe_r = tonumber(right) or 0
    self.safe_t = tonumber(top) or 0
    self.safe_b = tonumber(bottom) or 0
    self.installed = app == "1"
    self.vp_layout = tonumber(layout) or 0
    self.vp_visual = tonumber(visual) or 0
    self.vp_inner = tonumber(inner) or 0
    self.vp_outer = tonumber(outer) or 0
    self.vp_screen = tonumber(screen) or 0
    self.vp_top = tonumber(screen_y) or 0
    return locked
end

local function sample_performance(self, dt, stats)
    self.perf_t = (self.perf_t or 0) + dt
    self.perf_frames = (self.perf_frames or 0) + 1
    if self.perf_t < 1 then return end

    self.fps = self.perf_frames / self.perf_t
    self.frame_ms = 1000 * self.perf_t / self.perf_frames
    self.rx_rate = math.max(0, stats.rx - (self.rx_was or 0)) / self.perf_t
    self.tx_rate = math.max(0, stats.tx - (self.tx_was or 0)) / self.perf_t
    self.rx_was, self.tx_was = stats.rx, stats.tx
    self.perf_t, self.perf_frames = 0, 0
end

local function sample_link(self, dt, net)
    if not net.connected then
        self.link_meter = nil
        self.link_bars = 4
        return
    end
    if not self.link_meter then self.link_meter = link_quality.new() end
    self.link_bars = self.link_meter:update(net.stats.rtt, dt)
end

-- --- how far along the wait is ----------------------------------------------
--
-- The waiting screen draws one hairline across the box its PLAY NOW key will
-- take, and this is how full it is. The rail belongs to the page first:
-- `client/tools/single_file.py` puts it there before the engine exists, four
-- megabytes of runtime arriving and compiling under it, and hands over at
-- `BOOT`. What is left by then is a directory lookup, a dial and a first
-- snapshot, which is the stretch this owns.
--
-- Three marks rather than a clock, because three is all the client can
-- honestly report: the directory has answered, the socket has been welcomed,
-- and a room has sent a world. Between them the fill creeps toward the next
-- mark without ever reaching it, the way the page creeps through a compile
-- nothing can measure. The creep matters as much as the marks do. Those two
-- seconds are otherwise a wordmark on a drifting field with nothing else
-- moving on it, which is what a client that has hung looks like, and a fill
-- that ran on to the next mark early would be reporting a stage that has not
-- landed.
--
-- `BOOT` is written down in `single_file.py` too, as the ceiling its own
-- creep stops at. The two have to agree or the rail shrinks at the hand-off.
local BOOT, FOUND, LINKED = 0.72, 0.82, 0.92

-- Short of the next mark, so arriving at one is still a step somebody sees.
local SHORT = 0.02

function M.loading(self, dt, net, directory, stalled)
    local mark, next_mark = BOOT, FOUND
    if directory.answered then mark, next_mark = FOUND, LINKED end
    if net.connected then mark, next_mark = LINKED, 1 end
    local ceiling = next_mark - SHORT
    local at = self.load_bar or 0
    -- Forward to the mark the connection has actually reached, and back to
    -- the band it belongs in: a session that drops leaves the rail high, and
    -- a redial drawn at nine tenths would be a handshake reporting itself
    -- nearly done before it has been asked for.
    if at < mark then at = mark end
    if at > ceiling then at = ceiling end
    -- Stopped once something has gone wrong. A rail still climbing under "no
    -- games are running" is a client that looks like it is still trying.
    if not stalled then at = at + (ceiling - at) * math.min(dt, 1) * 0.9 end
    self.load_bar = at
    return at
end

-- Sample the page and the local frame counters on their one-second cadence.
function M.sample(self, dt, net, html5, locked)
    locked = poll_browser(self, dt, html5, locked)
    sample_performance(self, dt, net.stats)
    sample_link(self, dt, net)
    return locked
end

return M
