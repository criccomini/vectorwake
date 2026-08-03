-- The game browser.
--
-- Asks a directory what is running and lets the player pick. It speaks the
-- same protocol a zone does, so this needs no second transport, and it holds
-- nothing: close it and the answer is forgotten.
--
-- A player picks a game, not a machine. The directory's reply is a list of
-- zones with the instances running each one underneath, so a row here is a game
-- and choosing it takes the head of that zone's instance list -- which the
-- directory has already ordered so the head is the fullest one with room. The
-- address is shown but is not the thing being chosen, and the zone's name
-- travels with the join so arriving at an instance that has since changed game
-- is a refusal rather than a surprise.
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
    local ok, reply = pcall(json.decode, string.sub(s, 2))
    if not ok or type(reply) ~= "table" or type(reply.zones) ~= "table" then
        M.note = "the directory sent something unreadable"
        return
    end
    M.rows = {}
    for _, z in ipairs(reply.zones) do
        local up = z.instances and z.instances[1] or nil
        local players = z.players or 0
        M.rows[#M.rows + 1] = {
            zone = z.name,
            -- The head of the zone's list, already ordered by the directory so
            -- it is the fullest instance that still has room.
            address = up and up.address or "",
            name = z.name,
            detail = z.description or "",
            -- A zone with nobody running it is a row, not a gap: a player is
            -- better off seeing that Chaos exists and is down than wondering
            -- whether they misread the list.
            count = up
                and string.format("%d playing, %d AI", players, z.bots or 0)
                or "nobody is running it",
            live = up ~= nil,
        }
    end
    M.selected = 1
    M.note = (#M.rows == 0) and "the directory lists no games" or ""
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

-- The chosen game: an address to dial and the zone name to ask for. Nil when
-- the selection is a game nobody is currently running.
function M.chosen()
    local r = M.rows[M.selected]
    if r and r.live then return r.address, r.zone end
    return nil
end

-- Drawn through the same two-layer interface as everything else: shapes into
-- the screen-space mesh, text onto the shared list. `u` is the ui layer, `ui`
-- the layout module, so this file needs neither of their internals.
function M.draw(u, ui, w, h, s)
    if not M.open then return end
    local pal = require("arena.palette")

    u:rect(0, 0, w, h, pal.rgb(0x030509, 0.95))

    -- Laid out against the width there actually is. The row was a flat 640
    -- units wide and the margin assumed a 720-unit panel would fit, which on
    -- a phone is half again wider than the screen: the player count ran off
    -- the right edge and so did the end of every hint line.
    local x = math.max(24 * s, (w - 720 * s) / 2)
    local rw = math.min(640 * s, w - 2 * x)
    local y = 90 * s
    ui.line("v e c t o r w a k e", x, y, 30 * s, pal.FRIEND)
    ui.line("choose a game", x, y + 36 * s, 13 * s, pal.INK)
    -- Two short lines rather than one long one, for the same reason.
    ui.line("tap a game, tap it again to join", x, y + 56 * s, 13 * s, pal.DIM)
    ui.line("or ↑ ↓ and enter, esc plays offline",
            x, y + 74 * s, 13 * s, pal.DIM)

    y = y + 114 * s
    if M.note ~= "" then
        ui.line(M.note, x, y, 13 * s, pal.DIM)
        y = y + 26 * s
    end
    for i, r in ipairs(M.rows) do
        local on = i == M.selected
        local rh = 30 * s
        u:rect(x, h - y - rh, rw, rh, on and pal.BTN_SEL or pal.BTN_BG)
        u:frame(x, h - y - rh, rw, rh, s, on and pal.FRIEND or pal.BORDER)
        ui.line((on and "▸ " or "  ") .. r.name, x + 12 * s, y + rh / 2,
                13 * s, r.live and pal.INK or pal.DIM)
        -- Name, then what the game is, then how busy it is. No address: a
        -- player picks a game, and which machine serves it is the directory's
        -- business. It used to be drawn on the right, where a description long
        -- enough to be useful ran straight into it.
        -- The columns are shares of the row rather than fixed offsets, so a
        -- narrow screen squeezes them instead of pushing them off it. Below
        -- three columns' worth of room the description goes rather than
        -- overlapping the count, because which game it is and whether anybody
        -- is in it are the decision, and what it is like is a nicety.
        if rw / s >= 520 then
            ui.line(r.detail, x + rw * 0.30, y + rh / 2, 13 * s, pal.DIM)
        end
        ui.line(r.count, x + rw - 12 * s, y + rh / 2, 13 * s, pal.DIM, "right")
        -- A row is a button. Published in the space it was drawn in, the way
        -- the menu's rows are, so the input layer needs no second copy of this
        -- layout. Dead rows publish too: tapping a game nobody is running
        -- should select it and say so rather than doing nothing at all.
        ui.hit(x, y, rw, rh, "zone", i)
        y = y + rh + 6 * s
    end

    -- And a way out, because a phone has no escape key. Same reasoning as the
    -- menu's own close button, which exists for exactly this.
    local bw, bh = 200 * s, 34 * s
    u:rect(x, h - y - bh, bw, bh, pal.BTN_BG)
    u:frame(x, h - y - bh, bw, bh, s, pal.BORDER)
    ui.line("play offline", x + bw / 2, y + bh / 2, 13 * s, pal.DIM, "center")
    ui.hit(x, y, bw, bh, "offline")
end

return M
