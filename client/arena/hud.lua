-- The interface.
--
-- Two drawing spaces, and the difference matters. Text goes through
-- draw_text, which the render script draws under a screen-space projection.
-- Everything else -- bars, the radar, the frame around it -- is line
-- geometry, and draw_debug3d only draws in world space, so those are placed
-- at a fixed offset from the camera. That is the same trick the touch layer
-- uses, and it costs no second render pass.
--
-- This module reads the simulation and draws it. It decides nothing.

local M = {}

local INK    = vmath.vector4(0.78, 0.84, 0.94, 1)
local DIM    = vmath.vector4(0.42, 0.50, 0.62, 1)
local ACCENT = vmath.vector4(0.31, 0.84, 1.00, 1)
local WARN   = vmath.vector4(1.00, 0.45, 0.45, 1)
local GOOD   = vmath.vector4(0.45, 0.86, 0.60, 1)

local feed = {}

local function line(ax, ay, bx, by, col)
    msg.post("@render:", "draw_line", {
        start_point = vmath.vector3(ax, ay, 0),
        end_point = vmath.vector3(bx, by, 0), color = col})
end

local function text(s, x, y, col)
    msg.post("@render:", "draw_text", {
        text = s, position = vmath.vector3(x, y, 0), color = col})
end

-- A kill, for the feed. Names are resolved by the caller because only it
-- knows who is flying what.
function M.kill(killer, victim)
    table.insert(feed, 1, killer .. " killed " .. victim)
    while #feed > 8 do table.remove(feed) end
end

function M.reset()
    feed = {}
end

-- The energy bar every ship carries. Energy is health in this game -- it
-- powers the guns and it absorbs the damage -- so one bar says both things,
-- and a player who cannot see it has no way to know why a bomb did not fire.
function M.ship_bar(x, y, frac, hostile)
    local W, H = 22, 3
    local top = y - 24            -- above the hull; +y renders downward
    local col = hostile and WARN or GOOD
    if frac < 0.35 then col = WARN end
    -- The empty part, so the bar reads as a gauge rather than a shrinking
    -- stick that vanishes exactly when it matters most.
    line(x - W / 2, top, x + W / 2, top, DIM)
    if frac > 0 then
        local fw = W * frac
        for i = 0, H - 1 do
            line(x - W / 2, top + i, x - W / 2 + fw, top + i, col)
        end
    end
end

-- Radar. Drawn as world-space lines offset from the camera, which puts it at
-- a fixed screen corner without a second pass.
local function radar(cx, cy, hw, hh, me)
    local R = hh * 0.30                     -- radar half-extent on screen
    -- Bottom right. +y renders downward, so the larger y is the lower edge.
    local ox, oy = cx + hw - R - hh * 0.04, cy + hh - R - hh * 0.04
    local SPAN = 190 * 16                   -- world units the radar covers

    line(ox - R, oy - R, ox + R, oy - R, DIM)
    line(ox + R, oy - R, ox + R, oy + R, DIM)
    line(ox + R, oy + R, ox - R, oy + R, DIM)
    line(ox - R, oy + R, ox - R, oy - R, DIM)

    local myteam = sim.ship_team(me)
    for i = 0, sim.ship_count() - 1 do
        if sim.ship_alive(i) == 1 then
            local dx = (sim.ship_x(i) - cx) / SPAN * R * 2
            local dy = (sim.ship_y(i) - cy) / SPAN * R * 2
            if math.abs(dx) < R and math.abs(dy) < R then
                local col = (i == me) and ACCENT
                    or (sim.ship_team(i) == myteam and GOOD or WARN)
                local s = (i == me) and 2 or 1.5
                line(ox + dx - s, oy + dy, ox + dx + s, oy + dy, col)
                line(ox + dx, oy + dy - s, ox + dx, oy + dy + s, col)
            end
        end
    end

    for i = 0, sim.flag_count() - 1 do
        local fx, fy, team = sim.flag_at(i)
        local dx = (fx - cx) / SPAN * R * 2
        local dy = (fy - cy) / SPAN * R * 2
        if math.abs(dx) < R and math.abs(dy) < R then
            local col = (team == 255) and INK
                or (team == myteam and GOOD or WARN)
            line(ox + dx, oy + dy - 3, ox + dx, oy + dy + 1, col)
            line(ox + dx, oy + dy - 3, ox + dx + 3, oy + dy - 2, col)
        end
    end
end

-- opts: me, pilots, class_names, w, h, cam_x, cam_y, half_w, half_h, dead
function M.draw(o)
    local me = o.me
    if sim.ship_count() == 0 then return end

    radar(o.cam_x, o.cam_y, o.half_w, o.half_h, me)

    -- Own status, bottom left. Screen text origin is the bottom-left corner.
    local emax = math.max(1, sim.ship_max_energy(me))
    local frac = sim.ship_energy(me) / emax
    local cls = o.class_names[sim.ship_class(me) + 1] or "?"
    text(cls, 18, 92, ACCENT)
    text(string.format("ENERGY %d%%", math.floor(frac * 100 + 0.5)),
         18, 72, frac < 0.35 and WARN or INK)
    text(string.format("KILLS %d   DEATHS %d",
         sim.ship_kills(me), sim.ship_deaths(me)), 18, 52, DIM)

    -- Bombs are the expensive weapon, so say when one is affordable rather
    -- than letting the key look broken. A bomb is 17.6% of a full bar.
    local bombable = frac > 0.20
    text(bombable and "BOMB READY" or "BOMB: LOW ENERGY",
         18, 32, bombable and GOOD or DIM)

    -- Kill feed, above the status block and out of the world's way.
    local fy = 130
    for _, f in ipairs(feed) do
        text(f, 18, fy, DIM)
        fy = fy + 17
    end

    -- Player list, top right.
    local rows = {}
    for i = 0, sim.ship_count() - 1 do
        local p = o.pilots[i]
        rows[#rows + 1] = {
            i = i, name = (p and p.name) or ("ship " .. i),
            k = sim.ship_kills(i), d = sim.ship_deaths(i),
            team = sim.ship_team(i),
        }
    end
    table.sort(rows, function(a, b)
        if a.k ~= b.k then return a.k > b.k end
        return a.name < b.name
    end)
    local y = o.h - 24
    text("PILOT           K   D", o.w - 250, y, DIM)
    y = y - 20
    for _, r in ipairs(rows) do
        local col = (r.i == me) and ACCENT
            or (r.team == sim.ship_team(me) and INK or WARN)
        local nm = string.sub(r.name, 1, 14)
        text(string.format("%-14s %3d %3d", nm, r.k, r.d), o.w - 250, y, col)
        y = y - 18
    end

    if sim.ship_alive(me) == 0 then
        text("DESTROYED", o.w * 0.5 - 40, o.h * 0.5, WARN)
    end
end

return M
