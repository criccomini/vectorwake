-- Whether the fight is in front of the nose.
--
-- One question, asked by the stick: should a rearward push mean "back out of
-- this" rather than "turn around". The trigger answers it while it is held,
-- but a kite breathes: guns lift between bursts to let the energy climb, and
-- the ship backing out of a fight is still backing out of it during the
-- exhale. So the fight itself has to answer too, and the fight is a hostile
-- hull close enough to matter, roughly where the guns point.
--
-- Deliberately no more than that. Energy was considered as a signal and
-- refused: a control whose meaning flips at a threshold the player is not
-- watching is a control that betrays them mid-fight, and low energy is the
-- moment they can least afford it. So was what sits behind the ship: walls
-- stop a reversing ship harmlessly on their own, an enemy behind shows on the
-- radar, and a stick that refuses an order because it disapproves of the
-- destination is worse than a stick that obeys it. Who is ahead decides what
-- a gesture means; nothing decides whether to honor it.

local M = {}

-- How close a hostile has to be to count as the fight. The same thirty-two
-- tiles the server calls near combat when it picks a snapshot lane, so the
-- stick and the wire agree about what a fight is.
M.RANGE = 32 * 16

-- And how far off the nose it may sit, in radians. The complement of the
-- angle past which a rearward push stops steering the tail (REAR_EXIT in
-- arena/touch.lua), so an enemy stops counting as ahead exactly where a thumb
-- stops counting as behind.
M.AHEAD = 1.4

-- `s` is the simulation facade; `me` this client's ship, or nil watching.
function M.ahead(s, me)
    if not me then return false end
    local mx, my = s.ship_x(me), s.ship_y(me)
    local head = (s.ship_heading(me) / 65536) * math.pi * 2
    local mine = s.ship_team(me)
    for i = 0, s.ship_count() - 1 do
        if i ~= me and s.ship_active(i) ~= 0 and s.ship_alive(i) ~= 0
            and s.ship_team(i) ~= mine then
            local dx, dy = s.ship_x(i) - mx, s.ship_y(i) - my
            if dx * dx + dy * dy <= M.RANGE * M.RANGE then
                -- The bearing, in the sim's own sense: zero north, clockwise,
                -- +y down, which is the atan2(dx, -dy) the AI uses.
                local diff = math.atan2(dx, -dy) - head
                while diff > math.pi do diff = diff - math.pi * 2 end
                while diff < -math.pi do diff = diff + math.pi * 2 end
                if math.abs(diff) <= M.AHEAD then return true end
            end
        end
    end
    return false
end

return M
