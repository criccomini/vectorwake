-- Replay deep-link delivery, separated from the frame loop so the browser
-- route can be driven through its real fetch and playback handoff.

local M = {}

function M.new(deps)
    return function(state, route)
        local replay_id = type(route) == "string"
            and string.match(route, "^replay/(%d+)$") or nil
        if not replay_id then return nil end
        if state.replay_loading or not deps.ready()
            or (state.replay_after
                and (state.clock or 0) < state.replay_after) then
            return false
        end

        state.replay_loading = route
        state.replay_tries = (state.replay_tries or 0) + 1
        deps.note("loading match replay")
        deps.fetch(tonumber(replay_id), function(reply, why)
            if state.replay_loading ~= route then return end
            state.replay_loading = nil
            if not reply then
                if why == "no such match" and (state.replay_tries or 0) < 10 then
                    state.replay_after = (state.clock or 0) + 1
                    return
                end
                state.deep_route = nil
                deps.note(why or "cannot load match replay")
                return
            end
            state.deep_route = nil
            state.replay_after = nil
            state.replay_tries = nil
            deps.start(state, reply)
        end)
        return false
    end
end

return M
