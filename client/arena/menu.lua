-- The menu, which is the home screen and the one you open while flying.
--
-- The page opens on this, at the root, with nothing behind it: pick a hull,
-- take a different call sign if the one you were dealt is not to your taste,
-- and choose a game from the list the directory answers with. Escape opens the
-- same tree over a live arena, and every row means there what it meant on the
-- way in. One menu, learned once.
--
-- `home` is the only difference between the two. It says whether there is a
-- game behind the panel, and when there is not the menu cannot be closed,
-- because closing it would leave a player looking at an empty starfield with
-- no way back.
--
-- One list on screen at a time, a breadcrumb above it, and a stack behind it.
-- Down and up move, right or enter descends or acts, left or escape goes
-- back, and escape at the root closes. Five inputs, which is what a d-pad
-- has, what a phone can draw as four arrows and a button, and what a keyboard
-- already sends, so the same tree works on all three without a second layout.
-- A two-pane menu reads better on a desktop and falls apart at 390 points
-- wide.
--
-- Selection only, still: this decides nothing and steps nothing. It reports
-- an action and arena.script carries it out.

local account = require("arena.account")
-- For the protocol number the about page prints. Reading it from the module
-- that speaks it is what keeps the page honest when the wire changes.
local net = require("arena.net")
local callsign = require("arena.callsign")
local directory = require("arena.directory")
local sfx = require("arena.sfx")

local M = {}

M.open = true           -- the page opens on it
M.home = true           -- no game behind the panel
M.class = 0             -- the hull you are flying, kept in step with the sim
M.pending = nil         -- the hull a row just asked for
M.chosen = nil          -- the game a row just asked for
M.stack = {"root"}
M.sel = {}              -- selected row, per node, so a level remembers
M.note = nil            -- set by the arena when a connection fails

-- Who you are, where the games are, and which one you were in last.
--
-- Nothing here is typed. The name is generated, so a phone never has to raise
-- a keyboard and a console will hand us the platform's own name when we get
-- there. The directory is configuration rather than input: the zones list asks
-- it what is running and the player picks from the answer.
--
-- There is deliberately no address field. A game whose front door is a text
-- box asking for a websocket URL is a game with a text box in it, and the
-- machinery under one, an invisible DOM input over the canvas with focus
-- handed back and forth and enter delivered to whichever of the two had the
-- caret, was the single largest source of bugs in this client.
M.name = "pilot"
M.directory = "ws://127.0.0.1:9000"
M.zone = ""

-- Settings. Kept here because this is what saves them, and read by whoever
-- owns the thing they change.
M.volume = 3            -- index into VOLUMES
M.music = 3             -- index into MUSICS
M.cap = 1               -- index into CAPS
M.can_cap = false       -- whether this engine can be asked to cap frames

local VOLUMES = {{0, "off"}, {0.3, "quiet"}, {0.6, "half"}, {1.0, "full"}}
-- The soundtrack is its own mixer group and its own row, because wanting the
-- game loud and the music off is the commonest thing anybody wants out of a
-- game's audio and one number cannot say it. Its ceiling is below the
-- effects' on purpose: a soundtrack you have to shout over is one you turn
-- off, and then all this was for nothing.
local MUSICS = {{0, "off"}, {0.2, "quiet"}, {0.45, "half"}, {0.75, "full"}}
local CAPS = {{0, "display"}, {60, "60 a second"}, {30, "30 a second"}}

local SAVE = sys.get_save_file("vectorwake", "pilot")

function M.save_identity()
    pcall(sys.save, SAVE, {
        name = M.name, class = M.class, volume = M.volume, music = M.music,
        cap = M.cap, zone = M.zone,
    })
end

-- A call sign has to outlive the tab. Ratings are keyed by who you are, and a
-- player who is somebody new on every reload has no record to build.
function M.load_identity()
    callsign.seed(os.time() + math.floor(os.clock() * 100000))
    local ok, d = pcall(sys.load, SAVE)
    if ok and type(d) == "table" and type(d.name) == "string" and d.name ~= "" then
        M.name = d.name
        if type(d.class) == "number" then M.class = math.floor(d.class) % 8 end
        if type(d.volume) == "number" then M.volume = d.volume end
        if type(d.music) == "number" then M.music = d.music end
        if type(d.cap) == "number" then M.cap = d.cap end
        -- The game you were in last, so coming back puts the cursor on it and
        -- a returning player is one press from flying.
        if type(d.zone) == "string" then M.zone = d.zone end
    else
        M.name = callsign.generate()
        M.save_identity()
    end
    M.apply_settings()
end

-- Sound and frame rate are the two settings that reach outside this file.
-- Applied on load and on every change, so the menu never holds a value the
-- engine does not have.
function M.apply_settings()
    pcall(sound.set_group_gain, hash("master"), VOLUMES[M.volume][1])
    pcall(sound.set_group_gain, hash("music"), MUSICS[M.music][1])
    -- The effects do not all go through that mixer on the web, so the ones
    -- that do not have to be told the same number. See arena/sfx.lua.
    sfx.master_gain(VOLUMES[M.volume][1])
    -- A browser drives the frame loop from requestAnimationFrame, so on a
    -- 120 Hz laptop the game renders twice as often as on a 60 Hz one and
    -- costs twice the battery for it. The simulation is 100 Hz either way,
    -- so this is a picture setting, not a game one, which is exactly why
    -- it is the player's to make rather than ours.
    M.can_cap = pcall(sys.set_update_frequency, CAPS[M.cap][1])
end

function M.reroll()
    M.name = callsign.generate()
    M.save_identity()
end

-- The account's name wins once there is one. The arena takes the name from
-- the token rather than from the client, so a menu showing anything else is
-- showing a name nobody else can see.
function M.adopt_account_name()
    if account.name ~= "" and account.name ~= M.name then
        M.name = account.name
        M.save_identity()
    end
end

-- Configuration, for a build that is pointed somewhere: a test naming its
-- clients, or an operator running their own directory.
function M.defaults(name, dir)
    if name and name ~= "" then M.name = name end
    if dir and dir ~= "" then M.directory = dir end
end

-- --- the tree ---------------------------------------------------------------
--
-- A row is a label, an optional detail that may be a function of the moment,
-- and one of: `go` to descend, or `act` for the arena to carry out. A row with
-- neither is a line of text, which is what `about` is made of. A row may also
-- carry a `hint`, which is a sentence about it drawn under the list while it
-- is the row selected.
--
-- A node's `rows` is a table, or a function returning one when what is in the
-- list depends on the moment.

local HULLS = {
    {"Apex", "interceptor", "fastest, sharpest turn, lightest bar"},
    {"Wedge", "bomber", "heavy bombs on a short reload"},
    {"Chord", "skirmisher", "quick guns, no bomb rack"},
    {"Anvil", "heavy", "the biggest bar and the biggest bomb"},
    {"Spire", "support", "recharges faster than anything"},
    {"Cipher", "stealth", "hardest hitting gun, thinnest hull"},
    {"Facet", "brawler", "close in, and quick about it"},
    {"Lattice", "denial", "holds ground it has taken"},
}

local function hull_rows()
    local rows = {}
    for i, h in ipairs(HULLS) do
        rows[i] = {
            label = h[1], detail = h[3], act = "ship", value = i - 1,
            hull = i - 1, role = h[2],
            mark = function() return M.class == i - 1 end,
        }
    end
    return rows
end

-- Every side this room will tell us about, one to a row.
--
-- The zone's own first, then any private one we are on or hold an invitation
-- to, which is the order the server sends and the order a player thinks in.
-- The count is people and AI apart, because the caps are, and because "four
-- and eleven bots" is a different room from "fifteen".
local function team_rows()
    local rows = {}
    for _, t in ipairs(net.teams) do
        local mine = t.team == net.my_team
        rows[#rows + 1] = {
            label = t.name,
            detail = t.bots > 0 and (t.humans .. " + " .. t.bots .. " AI")
                or tostring(t.humans),
            act = "team", value = t.team,
            mark = function() return t.team == net.my_team end,
            hint = mine and "the side you are flying for"
                or (t.may_join and (t.public and "open to anybody with room in it"
                                    or "you have been invited to this one")
                    or (t.public and "full" or "invitation only")),
        }
    end
    -- A side of your own, when the room may hold another. A zone whose
    -- max_teams is the count of its own sides never offers this, which is how
    -- a flag round says there is no third side to be.
    if net.may_found then
        rows[#rows + 1] = {label = "new team", detail = "yours",
                           act = "found",
                           hint = "start a side and invite people to it"}
    end
    -- Inviting is not here. It was a second roster under this list, sorted by
    -- name, and the interface already had one you pick a person from: open the
    -- scoreboard, click whoever it is, and the box that answers who they are
    -- carries the invitation. Two rosters to keep in step was the cost, and a
    -- player who wants to invite somebody is usually already reading about
    -- them when they decide to.
    return rows
end

-- The games the directory is offering, one to a row.
--
-- Two columns only, so what a row says is its name and how busy it is, and the
-- sentence about what the game actually is goes under the list as the hint for
-- whichever row is selected. Both on the row was tried: "everybody against
-- everybody" beside "3 playing, 5 AI" is 45 characters against the 40 a phone
-- has room for, and the count is what decides while the description is what
-- explains.
local function zone_rows()
    local rows = {}
    for i, r in ipairs(directory.rows) do
        rows[i] = {
            label = r.name, detail = r.count, hint = r.detail,
            act = "join", value = i,
            mark = function() return r.zone == M.zone end,
        }
    end
    if #rows == 0 then
        -- Never an empty panel. Whatever the directory is doing, or failing to
        -- do, is the only thing this level has to say.
        --
        -- The hint carries the part that is about time rather than about what
        -- went wrong, and it goes under the list where there is room for a
        -- sentence: the detail is one right-aligned line already holding an
        -- address, and a phone has no width to spare on it. What it says is
        -- worth saying, because the answer to this used to be reloading the
        -- client and a player has no way to know it is not still.
        rows[1] = {label = "", detail = directory.note,
                   hint = "the list fills in by itself when a directory answers"}
    end
    return rows
end

local NODES = {
    root = {title = "vectorwake", rows = function()
        local rows = {
            {label = "play", detail = function()
                if M.zone ~= "" then return M.zone end
                return "choose a game"
            end, go = "zones"},
            {label = "ship", detail = function() return HULLS[M.class + 1][1] end,
             go = "ship"},
            {label = "pilot", detail = function() return M.name end, go = "pilot"},
            {label = "settings", go = "settings"},
            {label = "help", go = "help"},
            {label = "about", go = "about"},
        }
        -- Sides are a thing a room has, so the row appears with the room and
        -- says which one you are on. On the home screen there is no room and
        -- nothing to be on.
        if not M.home and #net.teams > 0 then
            table.insert(rows, 4, {label = "team",
                detail = function() return net.my_team_name() end,
                go = "teams",
                hint = "who you are flying with, and who else is here"})
        end
        -- Only with a game behind the panel, because it is the way out of one.
        -- On the home screen there is nothing to leave, and a row that does
        -- nothing is a row a player tries once and stops trusting.
        if not M.home then
            rows[#rows + 1] = {label = "leave", detail = "back to the menu",
                               act = "leave"}
        end
        return rows
    end},

    ship = {title = "ship", rows = hull_rows()},

    zones = {title = "games", rows = zone_rows},

    teams = {title = "team", rows = team_rows},

    pilot = {title = "pilot", rows = function()
        local rows = {
            {label = "call sign", detail = function() return M.name end,
             act = "reroll", hint = "a name is drawn for you and kept between visits"},
            {label = "", detail = function() return account.status() end},
        }
        -- A claim is offered rather than demanded, and never while a key is
        -- still on screen waiting to be written down.
        if account.key ~= "" then
            rows[#rows + 1] = {label = "your key", detail = account.key,
                hint = "write it down: this is the only way back in"}
            rows[#rows + 1] = {label = "done", act = "key_seen",
                hint = "clears the key from this screen"}
        elseif account.base ~= "" and not account.claimed then
            rows[#rows + 1] = {label = "keep this pilot", act = "claim",
                hint = "a key that brings this pilot back elsewhere"}
        end
        if account.claimed and account.key == "" then
            if account.link_code ~= "" then
                rows[#rows + 1] = {label = "code", detail = account.link_code,
                    hint = "type this on the other device within ten minutes"}
            else
                rows[#rows + 1] = {label = "add a device", act = "link",
                    hint = "shows a short code to type on the other device"}
            end
        end
        return rows
    end},

    settings = {title = "settings", rows = {
        {label = "sound", detail = function() return VOLUMES[M.volume][2] end,
         act = "volume"},
        {label = "music", detail = function() return MUSICS[M.music][2] end,
         act = "music"},
        {label = "frames", detail = function()
            if not M.can_cap then return "as the display asks" end
            return CAPS[M.cap][2]
        end, act = "cap"},
        {label = "fullscreen", detail = "fill the screen", act = "fullscreen"},
    }},

    -- The controls used to be a line of text across the bottom of the screen
    -- in every frame of every game. They are read once and never again, and
    -- on a phone they were laid over the thumbs, naming keys the device does
    -- not have while the controls it does have sat unexplained. A thing you
    -- consult belongs somewhere you go to consult it.
    help = {title = "help", rows = {
        {label = "", detail = "on a touchscreen"},
        {label = "steer", detail = "left thumb: point where you want the nose"},
        {label = "fire", detail = "right pads: guns, then bombs"},
        {label = "charges", detail = "tap a charge pad to spend it"},
        {label = "", detail = ""},
        {label = "", detail = "on a keyboard"},
        {label = "fly", detail = "arrow keys, or WASD"},
        {label = "guns", detail = "space, or Z"},
        {label = "bombs", detail = "shift, or X"},
        {label = "use", detail = "C, or ctrl"},
        {label = "swap", detail = "V, or tab"},
        -- Worth a line of its own. A fan is a liability down a corridor and
        -- arrives from a green rather than by choice, so a pilot who has one
        -- and does not know this key has a gun that got worse.
        {label = "one shot", detail = "Q, to stop multifire fanning"},
        {label = "scores", detail = "I, or the info button"},
        {label = "map", detail = "M, or click the radar"},
        {label = "who", detail = "click a pilot on the scoreboard"},
        {label = "menu", detail = "escape"},
        {label = "", detail = ""},
        -- Every key here has a second binding, and this is the reason. Most
        -- keyboards are a matrix that cannot report certain three-key
        -- combinations at all, and arrows-plus-space is one of the common
        -- casualties: turning stops working while you thrust and fire. No
        -- software can recover a keystroke the keyboard never sent, so the
        -- answer is a key on a different row.
        {label = "", detail = "if a third key stops working while two are held,"},
        {label = "", detail = "your keyboard cannot see that combination:"},
        {label = "", detail = "try Z for guns, or WASD to fly"},
    }},

    -- What this build is, rather than what the game is.
    --
    -- The page used to be six lines explaining energy and bounty, which is
    -- what `help` is for, and one build number at the bottom. Anybody who
    -- opens `about` in a game that updates several times a day wants to know
    -- which build they are looking at and what it is talking to, and that is
    -- the one question no other screen answers.
    about = {title = "about", rows = function()
        local rows = {
            {label = "build", detail = function()
                -- get_config_string, not get_config: the short name went out
                -- of the engine two versions before the one we build with,
                -- and calling it threw inside a draw, which on this renderer
                -- means the frame is never flushed and the last one stays on
                -- the GPU. That is why `about` looked like a menu that did
                -- nothing rather than a page that crashed.
                return sys.get_config_string("project.version", "dev")
            end, hint = "the commit this page was built from; + means it was dirty"},
            {label = "wire", detail = function()
                return "protocol " .. tostring(net.PROTOCOL)
            end, hint = "a zone speaking a different one refuses the join and says so"},
            {label = "engine", detail = function()
                return "defold " .. (sys.get_engine_info().version or "?")
            end},
            {label = "zone", detail = function()
                if M.zone == "" then return "not in one" end
                return M.zone
            end},
            {label = "account", detail = function()
                if account.account and account.account > 0 then
                    return "#" .. tostring(account.account)
                end
                return "none yet"
            end, hint = account.status()},
            {label = "", detail = ""},
            {label = "", detail = "inspired by subspace, and none of its"},
            {label = "", detail = "art, sound, maps or names"},
        }
        return rows
    end},
}

-- --- navigation -------------------------------------------------------------

local function node()
    return NODES[M.stack[#M.stack]]
end

local function rows_of(nd)
    local r = nd.rows
    if type(r) == "function" then return r() end
    return r
end

local function row_index(rows)
    local id = M.stack[#M.stack]
    local n = #rows
    local i = M.sel[id] or 1
    if i > n then i = n elseif i < 1 then i = 1 end
    M.sel[id] = i
    return i
end

-- Which level is on screen, so the arena knows when the games list is the
-- thing being read and can keep it fresh.
function M.at()
    return M.stack[#M.stack]
end

function M.toggle()
    if M.open then
        M.close()
    else
        M.open = true
        M.note = nil
    end
    return M.open
end

-- Open the menu at a particular level, which is what a failed connection
-- wants: the reason belongs next to the thing that would fix it.
function M.show(...)
    M.stack = {"root"}
    for _, id in ipairs({...}) do M.stack[#M.stack + 1] = id end
    M.open = true
end

-- Closing forgets where you were. A menu that reopens three levels down is a
-- menu that answers a different question than the one you asked it: the first
-- version of this kept the stack, and pressing escape then down then enter,
-- which had meant a play row a moment earlier, silently changed hull instead.
function M.close()
    -- Not while this is the only thing on screen. Escape at the root of the
    -- home screen is already as far back as there is to go.
    if M.home then return false end
    M.open = false
    M.stack = {"root"}
    -- The row as well as the level. Resetting only the stack left the root
    -- sitting on whatever was last chosen there, so escape-then-enter went
    -- wherever you went last time rather than into the first row, the same
    -- class of surprise one level up.
    M.sel = {}
    return true
end

local function back()
    if #M.stack > 1 then
        table.remove(M.stack)
        return nil, true
    end
    -- At the root with a game behind the panel, escape puts you back in it.
    -- With nothing behind the panel it gives up on a join that is still in
    -- flight, and means nothing at all when there is not one, which is why it
    -- reports nothing moved: the arena makes the noise if it turns out there
    -- was something to give up on.
    if M.close() then return nil, true end
    return "cancel", false
end

-- Put the cursor on the game you were in last, once the directory has
-- answered. Called by the arena rather than worked out during a draw, because
-- the list arrives on its own schedule and moving a selection out from under a
-- player mid-frame is exactly the surprise the stack reset above exists to
-- stop.
local zone_synced = false

function M.tick()
    if M.at() ~= "zones" then
        zone_synced = false
        return
    end
    if zone_synced or #directory.rows == 0 then return end
    zone_synced = true
    if M.zone == "" then return end
    for i, r in ipairs(directory.rows) do
        if r.zone == M.zone then M.sel.zones = i return end
    end
end

-- What the drawing code needs, and nothing about how it is drawn. `detail` is
-- resolved here so ui.lua never calls back into this file mid-frame.
function M.view()
    local nd = node()
    local rows = rows_of(nd)
    local sel = row_index(rows)
    -- The first screen a stranger sees, which is the only one that gets the
    -- name set large. Every other screen is a title on a column.
    local out = {title = nd.title, depth = #M.stack, sel = sel,
                 note = M.note, closable = not M.home or #M.stack > 1,
                 home_root = M.home and #M.stack == 1,
                 rows = {}}
    for i, r in ipairs(rows) do
        local d = r.detail
        if type(d) == "function" then d = d() end
        out.rows[i] = {
            label = r.label, detail = d, index = i, hull = r.hull,
            pick = (r.go or r.act) ~= nil,
            mark = r.mark and r.mark() or false,
        }
    end
    -- The sentence about whatever is under the cursor, drawn once under the
    -- list rather than squeezed onto every row.
    local cur = rows[sel]
    out.hint = cur and cur.hint or nil
    return out
end

-- Activate the selected row. Returns an action for the arena, or nil.
local function activate()
    local rows = rows_of(node())
    local r = rows[row_index(rows)]
    if not r then return nil end
    if r.go then
        M.stack[#M.stack + 1] = r.go
        M.note = nil
        return nil
    end
    if not r.act then return nil end

    -- The ones this file can settle itself.
    if r.act == "ship" then
        -- A request, not a decision. The hull you are flying is whatever the
        -- simulation says it is, and in a zone that is the server's answer and
        -- it can refuse, so this reports what was asked for and lets the arena
        -- find out. `M.class` follows the ship, never leads it.
        M.pending = r.value
        return "ship"
    elseif r.act == "team" then
        -- Likewise a request. Which sides exist, who may enter one, and whether
        -- this pilot is in any state to move are all the room's answers, and
        -- the team list it sends back is where they arrive.
        M.pending = r.value
        return "team"
    elseif r.act == "found" then
        return "found"
    elseif r.act == "join" then
        -- Likewise a request. Which address serves this game, and whether it
        -- answers, is the arena's business.
        M.chosen = directory.rows[r.value]
        return "join"
    elseif r.act == "reroll" then
        M.reroll()
        return nil
    elseif r.act == "claim" then
        account.claim(function(ok)
            if not ok then M.note = account.note end
        end)
        return nil
    elseif r.act == "key_seen" then
        -- Off the screen and out of memory. It was never written to disk: a
        -- key kept beside the secret it protects is a second copy of the same
        -- thing.
        account.key = ""
        return nil
    elseif r.act == "link" then
        account.link(function(ok)
            if not ok then M.note = account.note end
        end)
        return nil
    elseif r.act == "volume" then
        M.volume = M.volume % #VOLUMES + 1
        M.apply_settings()
        M.save_identity()
        return nil
    elseif r.act == "music" then
        M.music = M.music % #MUSICS + 1
        M.apply_settings()
        M.save_identity()
        return nil
    elseif r.act == "cap" then
        M.cap = M.cap % #CAPS + 1
        M.apply_settings()
        M.save_identity()
        return nil
    end
    return r.act
end

-- keys: {left, right, up, down, go, back} as booleans, already edge-detected
-- by the arena script: a tap can go down and up inside one frame and never
-- appear in the key state that flight reads.
--
-- Returns an action name or nil, and whether anything moved, so the caller
-- can make a noise about it.
function M.step(keys)
    if not M.open then return nil, false end

    if keys.back or keys.left then return back() end

    local id = M.stack[#M.stack]
    -- Built once. A node's rows may be a function, and asking it three times
    -- to move a cursor one row is three lists allocated to answer one
    -- keystroke.
    local rows = rows_of(node())
    local n = #rows
    if keys.up then
        M.sel[id] = (row_index(rows) - 2) % n + 1
        return nil, true
    end
    if keys.down then
        M.sel[id] = row_index(rows) % n + 1
        return nil, true
    end
    if keys.go or keys.right then return activate(), true end
    return nil, false
end

-- A pointer landed on a row the interface published.
function M.click(index)
    if not M.open then return nil, false end
    local id = M.stack[#M.stack]
    if index == -1 then return back() end
    M.sel[id] = index
    return activate(), true
end

return M
