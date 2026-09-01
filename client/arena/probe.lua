-- The client's own testimony about what it is showing.
--
-- The playtest harness in harness/ drives this client from a browser, and it
-- has to assert on something. Pixels answer no questions: the frame is
-- composited on the GPU, everything on it is moving, and reading it back tells
-- you a color and not whether a press would do anything. So the client says
-- what it is showing, in the terms the game already thinks in, and the harness
-- reads that.
--
-- Two rules kept this honest, and both are older than the harness.
--
-- The first is that a box is not a control. `M.pick` keeps the first box of the
-- highest priority, and a panel publishes `panel_hold` at priority 0 before any
-- row, so a row published at 0 afterwards is swallowed: the roster's
-- fly-this-ship press sat there for weeks resolving to nothing while a test
-- that only checked the box existed would have passed the whole time. So this
-- file does not publish rectangles and leave the reader to work out the rest.
-- It runs `ui.pick` at the middle of every box and publishes what actually
-- wins. A harness that wants to press a thing looks for the box that resolves
-- to that thing.
--
-- The second is that y runs two ways here. `ui.hits` is drawable pixels from
-- the top down; `touch.layout` is drawable pixels from the bottom up. Both are
-- converted once, here, into CSS pixels from the top down, which is the one
-- space a browser can be told to click in.
--
-- Nothing below is secret. It is the player's own view of their own screen,
-- which is why it can be compiled into the shipped client: disarmed it costs
-- one `html5.run` every two seconds and nothing else, and nothing in a URL can
-- arm it. The harness arms it with an init script, before the engine boots.

local M = {}

-- Fetched on the first reading rather than at load, because `arena.net` pulls
-- in the account, the transport and the engine's `sys` behind it, and this
-- file is required by the frame's browser end, which needs none of that. It
-- also keeps the encoder and the box arithmetic testable on a bare
-- interpreter.
local wired
local function wire()
    wired = wired or require("arena.net")
    return wired
end

-- Off until the page says otherwise, and re-asked at this interval so a driver
-- that attached after boot still gets an answer.
local ARM_EVERY = 2.0

-- Publishing every frame would put this file inside the frame time it reports.
-- Ten a second is faster than a hand and slow enough to stay out of the way.
local DEFAULT_HZ = 10

M.hz = 0
M.armed = false
local ask_in = 0
local due = 0
local seq = 0
-- Counted here rather than read off the arena, because the arena's counter is
-- the one-second performance sampler and resets itself. A harness watching for
-- a stalled client needs a number that only goes up.
local frames = 0

-- 255 is the watcher's seat and not a ship. Every accessor in the core range
-- checks it and throws, which froze a screen mid-flush once.
local function real_seat(i)
    if not i or i == 255 then return nil end
    if i < 0 or i >= sim.ship_count() then return nil end
    return i
end

-- --- JSON ------------------------------------------------------------------
--
-- Written out rather than pulled in because the client has no JSON encoder on
-- the Lua side and this needs about thirty lines. `string.format("%q")` is not
-- one: it writes a newline as a backslash and a real newline, which no JSON
-- parser accepts.

local ESCAPES = {
    ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
    ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function esc(c)
    return ESCAPES[c] or string.format("\\u%04x", string.byte(c))
end

local function enc_string(s)
    return '"' .. string.gsub(s, '[%c"\\]', esc) .. '"'
end

local function enc_number(n)
    -- A non-finite number is not JSON, and one reaching the harness as a
    -- literal `nan` would be a parse error rather than a reading.
    if n ~= n or n == math.huge or n == -math.huge then return "null" end
    if n == math.floor(n) and math.abs(n) < 1e15 then
        return string.format("%d", n)
    end
    return string.format("%.4f", n)
end

local enc

local function enc_table(v)
    local out, n = {}, #v
    if n > 0 then
        for i = 1, n do out[i] = enc(v[i]) end
        return "[" .. table.concat(out, ",") .. "]"
    end
    -- Sorted so two readings of an unchanged screen are the same string, which
    -- is what lets a harness notice that nothing moved.
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    if #keys == 0 then return "{}" end
    table.sort(keys)
    for i = 1, #keys do
        out[i] = enc_string(tostring(keys[i])) .. ":" .. enc(v[keys[i]])
    end
    return "{" .. table.concat(out, ",") .. "}"
end

enc = function(v)
    local t = type(v)
    if v == nil then return "null" end
    if t == "string" then return enc_string(v) end
    if t == "number" then return enc_number(v) end
    if t == "boolean" then return v and "true" or "false" end
    if t == "table" then return enc_table(v) end
    -- A function or userdata in the payload is a mistake upstream. Say which.
    return enc_string("<" .. t .. ">")
end

M.encode = enc

-- --- the reading -----------------------------------------------------------

-- What a press at the middle of each published box actually resolves to, in
-- CSS pixels. `ui.pick` is the same function `on_input` calls, so this is not
-- a model of the client's behavior, it is the behavior.
local function boxes(ui, density, touching)
    local out = {}
    local hits = ui.hits or {}
    for i = 1, #hits do
        local b = hits[i]
        local cx, cy = b.x + b.w / 2, b.y + b.h / 2
        -- `ui.pick` answers with the winning box, not with its action, and the
        -- winner may well be a different box than the one being measured.
        -- That difference is the whole point of publishing this.
        local won = ui.pick(cx, cy, touching)
        out[#out + 1] = {
            action = b.action,
            value = b.value,
            level = b.level,
            pri = b.pri or 0,
            x = cx / density,
            y = cy / density,
            w = b.w / density,
            h = b.h / density,
            -- What a press there does. Different from `action` means this box
            -- is covered: the press belongs to whatever is named here.
            hits = won and won.action or nil,
            hits_value = won and won.value or nil,
        }
    end
    return out
end

local function ships(net)
    local out = {}
    local count = sim.ship_count()
    for i = 0, count - 1 do
        -- A slot that is neither seated nor active is nobody: `ship_count` is
        -- a high-water mark, and a phantom row here would be a phantom row in
        -- anything reading this.
        if net.pilots[i] or sim.ship_active(i) == 1 then
            local p = net.pilots[i]
            out[#out + 1] = {
                seat = i,
                name = p and p.name or nil,
                ai = p and p.ai or nil,
                team = sim.ship_team(i),
                class = sim.ship_class(i),
                alive = sim.ship_alive(i) == 1,
                active = sim.ship_active(i) == 1,
                -- Raw, not drawn: the drawn position is interpolated between
                -- ticks and would never agree with a server snapshot.
                x = sim.ship_x_raw(i),
                y = sim.ship_y_raw(i),
                heading = sim.ship_heading_raw(i),
                energy = sim.ship_energy(i),
                max_energy = sim.ship_max_energy(i),
                kills = sim.ship_kills(i),
                deaths = sim.ship_deaths(i),
                assists = sim.ship_assists(i),
            }
        end
    end
    return out
end

local function pads(self, touch, density)
    if not self.vw or not self.vh then return nil end
    local ok, l = pcall(touch.layout, self.vw, self.vh, density)
    if not ok or type(l) ~= "table" then return nil end
    -- Bottom-up drawable pixels into top-down CSS pixels, once, here.
    local vh = self.vh
    local function place(p)
        if not p then return nil end
        return {
            x = p.x / density,
            y = (vh - p.y) / density,
            r = p.r / density,
            slot = p.slot,
            absent = p.absent,
        }
    end
    local sats = {}
    for i = 1, #(l.sats or {}) do sats[i] = place(l.sats[i]) end
    return {
        used = touch.used and true or false,
        guns = place(l.guns),
        bombs = place(l.bombs),
        home = place(l.home),
        sats = sats,
    }
end

local function reading(self, dt, html5, touch, ui, menu)
    local net = wire()
    local density = self.density or 1
    local eye = net.watching and real_seat(net.subject) or real_seat(net.me)
    local mine = eye and {
        seat = eye,
        alive = sim.ship_alive(eye) == 1,
        class = sim.ship_class(eye),
        team = sim.ship_team(eye),
        x = sim.ship_x_raw(eye),
        y = sim.ship_y_raw(eye),
        energy = sim.ship_energy(eye),
        max_energy = sim.ship_max_energy(eye),
    } or nil

    local go_act, go_value = ui.col_go()
    local tp = net.transport and net.transport() or nil

    seq = seq + 1
    return {
        seq = seq,
        -- Two clocks. `tick` is the simulation's and stalls when the wire
        -- does; `frames` is the client's own and stalls when the client does.
        -- A harness that watched only one would call the other kind of stall
        -- healthy.
        tick = sim.tick(),
        frames = frames,
        fps = self.fps,
        frame_ms = self.frame_ms,
        dt = dt,

        screen = {
            landing = menu.home and true or false,
            joined = ui.joined and true or false,
            watching = menu.watching and true or false,
            spectate = menu.spectate and true or false,
            flying = menu.flying(),
            menu_open = menu.open and true or false,
            column_up = ui.column_up(),
            -- The landing's panel, and the page inside the in-match column.
            panel = ui.col_open,
            section = ui.col_sect,
            hull_shown = ui.col_hull,
            page = menu.at(),
            depth = #menu.stack,
            -- A card takes every box on screen, so a harness that finds no
            -- box it wanted should look here before calling it a fault.
            card = (menu.ask ~= nil) or (ui.room_ask ~= nil),
            note = menu.note,
        },

        cursor = {
            action = ui.col_sel,
            value = ui.col_sel_value,
            -- What enter would fire from where the cursor is standing.
            go = go_act,
            go_value = go_value,
        },

        boxes = boxes(ui, density, touch.used and true or false),
        pads = pads(self, touch, density),

        me = mine,
        seat = net.me,
        subject = net.subject,
        ships = ships(net),

        room = {
            zone = net.zone,
            room = net.room,
            map = net.map_name,
            team = net.my_team,
        },

        link = {
            connected = net.connected and true or false,
            bars = self.link_bars,
            lost = net.lost,
            denied = net.denied,
            kind = tp and tp.kind or nil,
            rtt = net.stats and net.stats.rtt or nil,
            snaps = net.stats and net.stats.snaps or nil,
        },

        view = {
            w = self.vw,
            h = self.vh,
            density = density,
            -- CSS pixels, which is the space a browser clicks in.
            css_w = self.vw and self.vw / density or nil,
            css_h = self.vh and self.vh / density or nil,
        },
    }
end

-- Called at the end of every frame. Cheap when disarmed, which is always
-- unless something set `window.vwProbeHz` before the engine booted.
function M.finish(self, dt, html5, touch, ui, menu)
    if not html5 then return end
    frames = frames + 1

    if not M.armed then
        ask_in = ask_in - (dt or 0)
        if ask_in > 0 then return end
        ask_in = ARM_EVERY
        local ok, answer = pcall(html5.run,
            "window.vwProbeHz === undefined ? '' : String(window.vwProbeHz)")
        if not ok or type(answer) ~= "string" or answer == "" then return end
        M.hz = tonumber(answer) or DEFAULT_HZ
        if M.hz <= 0 then M.hz = 0 return end
        M.armed = true
        due = 0
    end

    due = due - (dt or 0)
    if due > 0 then return end
    due = 1 / M.hz

    -- The probe reports faults in itself rather than becoming one. An error
    -- raised in here would otherwise kill the frame it was measuring.
    local ok, payload = pcall(reading, self, dt, html5, touch, ui, menu)
    if ok then
        pcall(html5.run, "window.vwProbe=" .. enc(payload))
    else
        pcall(html5.run, "window.vwProbe={\"error\":"
            .. enc(tostring(payload)) .. "}")
    end
end

return M
