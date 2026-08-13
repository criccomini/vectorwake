-- Frame-level state that does not belong to flight, drawing, or menus.

local link_quality = require("arena.link_quality")

local M = {}

-- Recompute whether the connection has a world ready to draw. Call this again
-- after input handling because a menu action can join or leave during a frame.
function M.live(self, net, sim, menu)
    local live = self.online and net.connected and sim.ship_count() > 0
    menu.home = not live
    if not live then menu.open = true end
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

-- Sample the page and the local frame counters on their one-second cadence.
function M.sample(self, dt, net, html5, locked)
    locked = poll_browser(self, dt, html5, locked)
    sample_performance(self, dt, net.stats)
    sample_link(self, dt, net)
    return locked
end

return M
