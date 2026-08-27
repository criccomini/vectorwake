-- Per-frame UI state. Drawing domains share this object instead of closing
-- over a loose set of screen, mesh, text, and safe-area globals.

local M = {}
M.__index = M

function M.new(state)
    return setmetatable({
        state = state,
        w = 0,
        h = 0,
        scale = 1,
        -- What a CSS pixel is worth in drawable ones. Normally the same as
        -- `scale`, and not while the menu is up: the menu multiplies `scale`
        -- to set its type larger than the HUD's, and anything handed to the
        -- page has to be measured against the browser's own pixel rather than
        -- against that. See `MENU_ZOOM` in ui.lua.
        density = 1,
        layer = nil,
        text = nil,
        text_count = 0,
        -- The right edge everything drawn is cut against, or nil for the
        -- usual case of nothing being cut. The menu sets one while a page is
        -- sliding in, so a reading arrives from behind the column's own edge
        -- rather than across the fight beside it. See `vec.Layer:clip`.
        clip_r = nil,
        menu_up = false,
        text_dim = 1,
        case = "upper",
        now = 0,
        safe_l = 0,
        safe_r = 0,
        safe_t = 0,
        safe_b = 0,
        installed = false,
        zones = {},
    }, M)
end

function M:safe(left, right, top, bottom, installed)
    self.safe_l = left or 0
    self.safe_r = right or 0
    self.safe_t = top or 0
    self.safe_b = bottom or 0
    self.installed = installed and true or false
end

function M:begin(layer, w, h, density, now)
    self.layer = layer
    self.w = w
    self.h = h
    self.scale = density
    self.density = density
    self.now = now or 0
    self.text = self.state.text
    self.text_count = 0
    self.zones = {}
    layer:reset()
    -- Nothing is cut until something asks. The reset above uncovers the
    -- layer's own writers, so the two cannot come into a frame disagreeing.
    self.clip_r = nil
end

function M:finish()
    self.state.n = self.text_count
    self.state.version = self.state.version + 1
    self.layer:flush()
end

function M:ry(y, height)
    return self.h - y - (height or 0)
end

return M
