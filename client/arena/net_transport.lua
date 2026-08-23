-- WebSocket and WebTransport lifecycle, including QUIC fallback and liveness
-- timers. Protocol messages enter and leave through callbacks, so this module
-- never interprets game state.

local M = {}
M.__index = M

local WT_PATIENCE = 3
local WT_SETTLE = 5
local QUIET_LIMIT = 8

local function wtx()
    return rawget(_G, "webtransport")
end

function M.new()
    return setmetatable({
        callbacks = nil,
        conn = nil,
        wt_live = false,
        pending = nil,
        settling = nil,
        quiet = nil,
        avoid = {},
        tried = false,
        reason = nil,
        join = nil,
        generation = 0,
    }, M)
end

function M:configure(callbacks)
    self.callbacks = callbacks
end

function M:has_wire()
    return self.conn ~= nil or self.wt_live
end

function M:is_webtransport()
    return self.wt_live
end

function M:send_reliable(message)
    if self.wt_live then
        pcall(wtx().send, message)
    elseif self.conn then
        pcall(websocket.send, self.conn, message,
              {type = websocket.DATA_TYPE_BINARY})
    end
end

-- Inputs use a datagram on WebTransport and the shared socket everywhere
-- else. Each input packet carries its own repair window, so transport-level
-- retransmission is unnecessary.
function M:send_unreliable(message)
    if self.wt_live then
        pcall(wtx().send_unreliable, message)
    elseif self.conn then
        pcall(websocket.send, self.conn, message,
              {type = websocket.DATA_TYPE_BINARY})
    end
end

-- Close both possible wires. Decode failures and explicit departures share
-- this path so neither can leave a ghost session open.
function M:hangup()
    if self.conn then pcall(websocket.disconnect, self.conn) end
    self.conn = nil
    local extension = wtx()
    if extension then pcall(extension.disconnect) end
    self.wt_live = false
    self.pending = nil
    self.settling = nil
    self.quiet = nil
end

-- Make every callback still in flight stale before an explicit departure.
function M:invalidate()
    self.generation = self.generation + 1
end

function M:progress()
    self.callbacks.progress()
    if self.settling then self.settling = 0 end
end

-- A snapshot proves the handshake, reliable lane, and snapshot lane all work.
function M:prove()
    self.settling = nil
    self.quiet = 0
end

local function socket_error(data)
    if data.message then return tostring(data.message) end
    return "could not reach that zone"
end

function M:dial_ws()
    local generation = self.generation
    self.callbacks.wire("ws")
    return pcall(function()
        self.conn = websocket.connect(self.join.url, {}, function(_, connection, data)
            if generation ~= self.generation then return end
            if data.event == websocket.EVENT_CONNECTED then
                -- Use the callback's handle. A synchronous connected event can
                -- arrive before websocket.connect has returned its handle.
                pcall(websocket.send, connection, self.callbacks.join_message(),
                      {type = websocket.DATA_TYPE_BINARY})
            elseif data.event == websocket.EVENT_MESSAGE then
                self.callbacks.message(data.message)
            elseif data.event == websocket.EVENT_DISCONNECTED then
                self.callbacks.lost("the zone closed the connection")
            elseif data.event == websocket.EVENT_ERROR then
                self.callbacks.lost(socket_error(data))
            end
        end)
    end)
end

-- A QUIC door that fails once is skipped for later joins to that same address.
-- Other zones still get their own attempt.
function M:fall_back()
    if self.join and self.join.wt ~= "" then self.avoid[self.join.wt] = true end
    self.pending = nil
    self.settling = nil
    self.wt_live = false
    self.callbacks.progress()
    self.generation = self.generation + 1
    local extension = wtx()
    if extension then pcall(extension.disconnect) end
    if not self:dial_ws() then
        self.callbacks.lost("that address is not a zone URL")
    end
end

function M:dial_wt(url)
    local generation = self.generation
    self.wt_live = false
    self.tried = true
    self.pending = 0
    self.callbacks.wire("wt")
    local extension = wtx()
    self.reason = nil
    local ok = pcall(extension.connect, url, function(_, data)
        if generation ~= self.generation then return end
        if data.event == extension.EVENT_CONNECTED then
            self.pending = nil
            -- Opened is not delivering. The reliable lane still has to carry
            -- the welcome and the snapshot lane has to prove the session.
            self.settling = 0
            self.wt_live = true
            self:send_reliable(self.callbacks.join_message())
        elseif extension.EVENT_PROGRESS
            and data.event == extension.EVENT_PROGRESS then
            self:progress()
        elseif data.event == extension.EVENT_MESSAGE then
            self.callbacks.message(data.message)
        elseif self.pending then
            if data.message and data.message ~= "" then
                self.reason = tostring(data.message)
            end
            self:fall_back()
        else
            self.wt_live = false
            self.callbacks.lost("the zone closed the connection")
        end
    end)
    if not ok then self:fall_back() end
end

function M:connect(join)
    self.join = join
    self.tried = false
    local extension = wtx()
    if join.wt and join.wt ~= "" and extension and extension.supported()
        and not self.avoid[join.wt] then
        self:dial_wt(join.wt)
        return true
    end
    if not self:dial_ws() then
        self.callbacks.lost("that address is not a zone URL")
        return false
    end
    return true
end

function M:last_join()
    if not self.join then return nil end
    return {
        url = self.join.url,
        zone = self.join.zone,
        wt = self.join.wt or "",
        watch = self.join.watch,
        room = self.join.room,
        instance = self.join.instance,
    }
end

function M:info()
    local extension = wtx()
    local url = self.join and self.join.url or ""
    local door = self.join and self.join.wt or ""
    return {
        kind = (self.wt_live and "wt") or (self.conn and "ws") or nil,
        secure = string.sub(url, 1, 6) == "wss://",
        able = extension ~= nil and extension.supported() or false,
        refused = door ~= "" and self.avoid[door] == true,
        offered = door ~= "",
        tried = self.tried,
        reason = self.reason,
        trying = self.pending ~= nil or self.settling ~= nil,
    }
end

function M:tick(dt, connected)
    if self.pending then
        self.pending = self.pending + dt
        if self.pending >= WT_PATIENCE then self:fall_back() end
    end
    if self.settling then
        self.settling = self.settling + dt
        if self.settling >= WT_SETTLE then self:fall_back() end
    end
    if self.quiet and connected then
        -- A backgrounded tab wakes with one large dt. An outage is many quiet
        -- frames, so cap one frame's contribution to the liveness verdict.
        self.quiet = self.quiet + math.min(dt, 0.1)
        if self.quiet >= QUIET_LIMIT then
            self.callbacks.lost("the zone went quiet")
        end
    end
end

return M
