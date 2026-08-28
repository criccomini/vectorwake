-- Shared engine stand-ins for interface tests.

local M = {}

function M.noop() end

function M.layer()
    local layer = {}
    for _, name in ipairs({
        "arc", "arc_aa", "bloom", "clip", "disc", "fan", "flush", "frame",
        "glow_band", "halo", "outline", "quad", "rect", "reset", "resize",
        "ring", "ring_aa", "ring_fade", "seg", "seg_fade", "seg_flat",
        "seg_glow", "skirt", "tri", "tri_fade", "unclip",
    }) do
        layer[name] = M.noop
    end
    -- The one layer call that answers rather than draws: how many facets a
    -- circle of this radius is worth. A caller loops over it, so a stand-in
    -- that returned nothing would hang or draw nothing at all.
    layer.round_segs = function(_, r)
        return math.max(12, math.min(96, math.ceil((r or 1) / 2)))
    end
    return layer
end

local function sim_stub()
    return setmetatable({}, {
        __index = function() return function() return 0 end end,
    })
end

local function world_stub()
    return {
        build_overview = M.noop,
        forget_overview = M.noop,
        overview = function() return {grid = 0} end,
        radar_tiles = {},
        radar_safe = {},
        radar_doors = {},
        HULLS = setmetatable({}, {
            __index = function()
                return {poly = {0, 0, 1, 1, 2, 0}, mid = 0}
            end,
        }),
    }
end

function M.install(options)
    options = options or {}
    _G.sim = options.sim or sim_stub()
    package.loaded["arena.state"] = options.state
        or {text = {}, n = 0, version = 0}
    package.loaded["arena.touch"] = options.touch
        or {layout = function() return {charge = {}} end, used = false}
    package.loaded["arena.world"] = options.world or world_stub()
    package.loaded["arena.ui"] = nil
    return require("arena.ui"), package.loaded["arena.state"]
end

return M
