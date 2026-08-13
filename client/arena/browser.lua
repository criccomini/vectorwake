-- The browser-facing end of a frame: pointer, DOM overlays, and handoff.

local M = {}

local CURSOR_HOLD = 2.0
local CURSOR_FADE = 0.5

local function draw_cursor(self, dt, h, html5, touch, ui)
    self.cursor_idle = (self.cursor_idle or 0) + dt
    if not html5 or not self.cursor_x or touch.used then return end

    local ok, out = pcall(html5.run, "window.vwPointerOut?1:0")
    local alpha = math.min(1,
        (CURSOR_HOLD + CURSOR_FADE - self.cursor_idle) / CURSOR_FADE)
    if (ok and out == "1") or alpha <= 0 then
        self.cursor_x, self.cursor_y = nil, nil
    else
        ui.cursor(self.cursor_x, h - self.cursor_y, alpha)
    end
end

local function publish_link(self, html5, ui)
    local link = ui.link_dom
    if link == self.link_dom then return end
    self.link_dom = link
    pcall(html5.run, "window.vwLink && vwLink('" .. (link or "") .. "')")
end

local function publish_ask(self, html5, touch, ui, menu, sfx, apply_menu)
    local spec = ui.ask_dom
    if spec ~= self.ask_dom then
        self.ask_dom = spec
        menu.dom = spec ~= nil
        local take = (not touch.used) and ", 1" or ""
        pcall(html5.run,
              "window.vwAsk && vwAsk('" .. (spec or "") .. "'" .. take .. ")")
    end
    if not spec then return end

    local ok, pressed = pcall(html5.run,
                              "window.vwAskGo ? window.vwAskGo() : ''")
    local ask = menu.ask
    if not ok or type(pressed) ~= "string" or pressed == ""
       or not ask or not ask.keys then return end

    local i = string.find(pressed, "b", 1, true) and #ask.keys or 1
    local act, moved = menu.click_answer(i)
    if moved then sfx.ui(act and "ui_go" or "ui_move") end
    if act then apply_menu(self, act) end
end

function M.finish(self, dt, h, html5, touch, ui, menu, sfx, apply_menu)
    draw_cursor(self, dt, h, html5, touch, ui)
    ui.finish()

    if html5 then
        publish_link(self, html5, ui)
        publish_ask(self, html5, touch, ui, menu, sfx, apply_menu)
    end

    if not self.handed_over then
        self.handed_over = true
        if html5 then pcall(html5.run, "window.vwReady && vwReady()") end
    end
end

return M
