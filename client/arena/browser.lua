-- The server browser.
--
-- Asks a directory what is running and lets the player pick. It speaks the
-- same protocol a zone does, so this needs no second transport, and it holds
-- nothing: close it and the answer is forgotten.
--
-- A directory being unreachable is not an error worth blocking on. The client
-- is playable with nothing behind it, so a browser that cannot reach anything
-- simply says so and gets out of the way.

local M = {}

local C2S_STATUS = 4
local S2C_STATUS = 8

M.open = false
M.rows = {}
M.selected = 1
M.note = "looking for zones"

local conn = nil

local function on_message(s)
    if string.byte(s, 1) ~= S2C_STATUS then return end
    local ok, list = pcall(json.decode, string.sub(s, 2))
    if not ok or type(list) ~= "table" then
        M.note = "the directory sent something unreadable"
        return
    end
    M.rows = {}
    for _, e in ipairs(list) do
        local st = e.status
        M.rows[#M.rows + 1] = {
            address = e.address,
            -- A zone that is listed but not answering is a row, not a gap:
            -- the player is better off seeing it is down than wondering.
            name = st and st.name or e.address,
            detail = st
                and string.format("%d playing, %d AI", st.players or 0, st.bots or 0)
                or "not answering",
            live = st ~= nil,
        }
    end
    M.selected = 1
    M.note = (#M.rows == 0) and "the directory lists no zones" or ""
end

function M.connect(url)
    M.open = true
    M.rows = {}
    M.note = "looking for zones"
    conn = websocket.connect(url, {}, function(self, cid, data)
        if data.event == websocket.EVENT_CONNECTED then
            websocket.send(conn, string.char(C2S_STATUS),
                           {type = websocket.DATA_TYPE_BINARY})
        elseif data.event == websocket.EVENT_MESSAGE then
            on_message(data.message)
        elseif data.event == websocket.EVENT_DISCONNECTED
            or data.event == websocket.EVENT_ERROR then
            conn = nil
            if #M.rows == 0 then M.note = "no directory at " .. url end
        end
    end)
end

function M.close()
    if conn then websocket.disconnect(conn) end
    conn = nil
    M.open = false
end

function M.move(delta)
    if #M.rows == 0 then return end
    M.selected = M.selected + delta
    if M.selected < 1 then M.selected = #M.rows end
    if M.selected > #M.rows then M.selected = 1 end
end

-- The chosen address, or nil when the selection is a zone that is not up.
function M.chosen()
    local r = M.rows[M.selected]
    if r and r.live then return r.address end
    return nil
end

-- Drawn through the same two-layer interface as everything else: shapes into
-- the screen-space mesh, text onto the shared list. `u` is the ui layer, `ui`
-- the layout module, so this file needs neither of their internals.
function M.draw(u, ui, w, h, s)
    if not M.open then return end
    local pal = require("arena.palette")

    u:rect(0, 0, w, h, pal.rgb(0x030509, 0.95))

    local x = math.max(40 * s, (w - 720 * s) / 2)
    local y = 90 * s
    ui.line("v e c t o r w a k e", x, y, 30 * s, pal.FRIEND)
    ui.line("choose a zone", x, y + 36 * s, 13 * s, pal.INK)
    ui.line("↑ ↓ move    enter joins    esc plays offline",
            x, y + 56 * s, 13 * s, pal.DIM)

    y = y + 96 * s
    if M.note ~= "" then
        ui.line(M.note, x, y, 13 * s, pal.DIM)
        y = y + 26 * s
    end
    for i, r in ipairs(M.rows) do
        local on = i == M.selected
        local rw, rh = 640 * s, 30 * s
        u:rect(x, h - y - rh, rw, rh, on and pal.BTN_SEL or pal.BTN_BG)
        u:frame(x, h - y - rh, rw, rh, s, on and pal.FRIEND or pal.BORDER)
        ui.line((on and "▸ " or "  ") .. r.name, x + 12 * s, y + rh / 2,
                13 * s, r.live and pal.INK or pal.DIM)
        ui.line(r.detail, x + 300 * s, y + rh / 2, 13 * s, pal.DIM)
        ui.line(r.address, x + rw - 12 * s, y + rh / 2, 13 * s, pal.DIM,
                "right")
        y = y + rh + 6 * s
    end
end

return M
