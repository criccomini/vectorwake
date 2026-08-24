-- The action routes consumed by arena.script.
--
-- controls.lua owns what the game offers a pilot. This module owns the other
-- side of that contract: which simulation bit, charge latch, or interface
-- action receives each control. Keeping the routes as data lets the arena use
-- the same object a test can inspect, instead of asking a test to recognize
-- source spellings in a large script.

local M = {}

local PANEL_ORDER = {"menu", "details", "players", "map", "help"}

-- Deliver every panel action through one seam. `players` is the ordered gap
-- where Page Up and Page Down run, so simultaneous presses keep the same
-- details, player, map, help order the frame loop has always used. A handler
-- may return false to leave an action pending.
function M.dispatch_panel(tapped, routes, handlers, live)
    for _, id in ipairs(PANEL_ORDER) do
        if id == "players" then
            handlers.players(tapped, live)
        else
            local action = routes[id]
            if tapped[action] then
                if handlers[id](tapped, live) ~= false then
                    tapped[action] = nil
                end
            end
        end
    end
end

function M.new(hash_fn, sim)
    local out = {}

    out.flight = {
        turn_left = {action = hash_fn("turn_left"), bit = sim.BTN_LEFT},
        turn_right = {action = hash_fn("turn_right"), bit = sim.BTN_RIGHT},
        thrust = {action = hash_fn("thrust"), bit = sim.BTN_THRUST},
        reverse = {action = hash_fn("reverse"), bit = sim.BTN_REVERSE},
        guns = {action = hash_fn("guns"), bit = sim.BTN_FIRE},
        bombs = {action = hash_fn("bombs"), bit = sim.BTN_BOMB},
        -- Held rather than tapped on purpose. The core toggles multifire on
        -- the rising edge, so reporting the held key leaves that edge in one
        -- place instead of detecting it again in the client.
        multi = {action = hash_fn("multi"), bit = sim.BTN_MULTI},
    }
    out.bits = {}
    for _, route in pairs(out.flight) do
        out.bits[route.action] = route.bit
    end

    out.charge = {}
    for i = 1, sim.KIT_CHARGE_SLOTS do
        local id = "charge_" .. i
        out.charge[i] = {id = id, action = hash_fn(id)}
    end

    out.panel = {
        menu = hash_fn("menu"),
        details = hash_fn("details"),
        map = hash_fn("map"),
        help = hash_fn("help"),
    }
    out.players = {
        {id = "player_prev", action = hash_fn("player_prev"), direction = -1},
        {id = "player_next", action = hash_fn("player_next"), direction = 1},
    }

    -- Pointer actions are engine inputs, not controls the bindings page
    -- offers. They still land in the same simulation button map.
    out.pointer_bits = {
        [hash_fn("pointer")] = sim.BTN_FIRE,
        [hash_fn("pointer_alt")] = sim.BTN_BOMB,
        [hash_fn("guns_ctrl")] = sim.BTN_FIRE,
    }
    out.dispatch_panel = M.dispatch_panel

    return out
end

return M
