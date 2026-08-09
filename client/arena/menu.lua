-- The menu, which is the home screen and the one you open while flying.
--
-- The page opens on this with nothing behind it, and on the games: the list
-- the directory answers with, cursor already in it, on the game you were in
-- last. The rail beside it goes to a different hull, a different call sign,
-- the settings. Escape opens the same tree over a live arena, and every row
-- means there what it meant on the way in. One menu, learned once.
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
-- The hulls are the one page laid out in two dimensions rather than one, so
-- there the arrows mean a column and a row and only enter picks. See `grid`
-- on the node and the branch it takes in `step`.
--
-- Selection only, still: this decides nothing and steps nothing. It reports
-- an action and arena.script carries it out.

local account = require("arena.account")
-- For the protocol number the about page prints. Reading it from the module
-- that speaks it is what keeps the page honest when the wire changes.
local net = require("arena.net")
local callsign = require("arena.callsign")
local directory = require("arena.directory")
local clip = require("arena.clip")
local sfx = require("arena.sfx")

local M = {}

M.open = true           -- the page opens on it
M.home = true           -- no game behind the panel
M.class = 0             -- the hull you are flying, kept in step with the sim
M.watching = false      -- sitting out, set by the arena each frame
-- What you will arrive as, which the ship page sets and a join carries. It is
-- remembered like the hull is, because it is the same choice: a player who
-- came to watch is still there to watch after a reload.
M.spectate = false
M.pending = nil         -- the hull a row just asked for
M.chosen = nil          -- the game a row just asked for
M.stack = {"root"}
M.sel = {}              -- selected row, per node, so a level remembers
M.hover = nil           -- the stage row a pointer is resting on
M.note = nil            -- set by the arena when a connection fails
M.screen = nil          -- the drawable and its insets, for the about page
-- What a key is made of, and how long one is. Both are the server's, written
-- down here because the slots are drawn against them and what a keyboard hands
-- us is filtered against them. Crockford's alphabet without the letters that
-- get misread by hand: no I, L, O or U.
local KEY_CHARS = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
local KEY_LEN = 12

-- A question the menu wants answered before it will do anything else, and
-- nothing while there is none. Whoever raises it fills in the words and what
-- each answer is worth; this file knows only that the last answer is the one
-- that changes nothing, which is the one escape gives and the one the cursor
-- starts on.
M.ask = nil             -- {head = "...", keys = {{label, act}}, sel = n}
-- Whether the games list has worked out where its cursor belongs since it was
-- last opened. Declared up here because opening the menu clears it and the
-- opening is written above the asking.
local zone_synced = false
-- How many hulls the ship page is drawing across, set by whoever draws it.
-- The page is a grid rather than a list and its arrows have to mean what a
-- grid's arrows mean, which needs the one number this file cannot work out
-- for itself: that depends on the width of a window.
M.cols = 4

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

-- Whether the ship page's answer is currently "no hull". In a game that is
-- what the connection says you are; on the home screen it is what you have
-- asked to arrive as. One question, two places it can be answered from.
function M.spectating()
    if M.home then return M.spectate end
    return M.watching
end

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
        cap = M.cap, zone = M.zone, spectate = M.spectate,
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
        -- What you last chose to arrive as. Saved beside the hull because it
        -- is an answer to the same question the hull answers.
        M.spectate = d.spectate == true
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
-- is the row selected, or a `note`, which is a sentence drawn in the row
-- itself, under its name, whether or not the cursor is on it. A list whose
-- rows are things to choose between wants notes; one whose rows are controls
-- wants hints, because a sentence about what a control will do is only worth
-- the room while you are on it.
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
            -- Not while the answer is "none of them". A watcher is in no
            -- hull, so marking the one they would fly back in would put the
            -- "you are here" wash on a ship nobody is sitting in.
            mark = function() return not M.spectating() and M.class == i - 1 end,
        }
    end
    -- Sitting out is the ninth thing you can be flying, so it is the ninth
    -- cell rather than a row somewhere else. Picking a hull is already how a
    -- pilot says what they want to be; "nothing, I am watching" is an answer
    -- to that question and belongs beside the other eight.
    --
    -- On the home screen too, where this page is what you will arrive as
    -- rather than what you are. Arriving to watch is a thing the wire has
    -- always been able to say, so picking it here is a choice that carries
    -- into the join rather than a control that waits for a game to exist.
    rows[#rows + 1] = {
        label = "Spectate", detail = "watch the room from nobody's cockpit",
        act = "spectate", role = "no hull",
        -- The helmet, not a ship: the cell is about the pilot rather than
        -- about anything they are flying.
        figure = "pilot",
        mark = function() return M.spectating() end,
    }
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
            -- Somebody named this side, so it is drawn the way they named it
            -- rather than the way this interface says its own words.
            label = t.name, named = true,
            -- And in the colour that side wears on every plate in the arena,
            -- so this list is where the colours get their names. Yours is
            -- cyan here as it is everywhere: `tint` is the byte, and ui.lua
            -- decides what "yours" means, since it is the side the camera is
            -- behind rather than the one this menu belongs to.
            tint = t.team,
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
            label = r.name, detail = r.count,
            -- A zone the directory lists with no arena behind it. The row
            -- keeps its place, because a player is better off seeing that
            -- Chaos exists and is down than wondering whether they misread
            -- the list, and it wears the dial that is looking for one rather
            -- than a sentence saying nobody is.
            waiting = not r.live,
            -- What the game is, under its own name rather than at the foot of
            -- the panel. Choosing between three games is reading three
            -- sentences; one at a time, a long way from the name it belongs
            -- to, is not reading them.
            note = r.detail,
            -- What the meter draws, when the interface would rather show a
            -- room's population than spell it.
            players = r.players, bots = r.bots, live = r.live,
            act = "join", value = i,
        }
    end
    -- Nothing about leaving down here. The way out of a game is the game's own
    -- row: choosing the one you are already in asks whether that is what you
    -- meant. A row at the foot of the list was a way out written a long way
    -- from the thing it was a way out of, and it stood in a list that is
    -- otherwise entirely places to go.
    return rows
end

-- What the games page holds instead of games. See `empty` on the node: a
-- blank row carrying the directory's note was what this was, which is a row
-- pretending to be a game and a sentence pretending to be a name.
local function zone_empty()
    if #directory.rows > 0 then return nil end
    return {head = directory.note, line = directory.why}
end

local NODES = {
    root = {rows = function()
        local rows = {
            {label = "zones", icon = "zones", detail = function()
                if M.zone ~= "" then return M.zone end
                return "choose a game"
            end, go = "zones"},
            {label = "ship", icon = "ship",
             detail = function()
                 if M.spectating() then return "spectating" end
                 return HULLS[M.class + 1][1]
             end,
             go = "ship"},
            {label = "pilot", icon = "pilot",
             detail = function() return M.name end, go = "pilot"},
            {label = "settings", icon = "settings", go = "settings"},
            {label = "help", icon = "help", go = "help"},
            {label = "about", icon = "about", go = "about"},
        }
        -- Sides are a thing a room has, so the row appears with the room and
        -- says which one you are on. On the home screen there is no room and
        -- nothing to be on.
        if not M.home and #net.teams > 0 then
            table.insert(rows, 4, {label = "team", icon = "team",
                detail = function() return net.my_team_name() end,
                go = "teams",
                hint = "who you are flying with, and who else is here"})
        end
        return rows
    end},

    -- A grid, not a list: the hulls are drawings laid out in rows and columns,
    -- so left and right are a column apart and up and down are a row apart.
    -- Nothing else in the tree is, which is why it is a flag on the node
    -- rather than a rule about pages.
    -- A function rather than a table: the page is eight cells on the home
    -- screen and nine with a game behind it, so it has to be asked each time
    -- rather than built once at load.
    ship = {grid = true, rows = hull_rows},

    zones = {rows = zone_rows, empty = zone_empty},

    teams = {rows = team_rows},

    pilot = {rows = function()
        local rows = {
            -- What the account layer makes of you rides on the hint line
            -- rather than in a row of its own. It is a sentence, and a
            -- sentence in the value column of a row with no label floated in
            -- the middle of the panel attached to nothing.
            {label = "call sign", detail = function() return M.name end,
             -- A call sign is upper, lower and numeric as its owner has it.
             verbatim = true, act = "reroll",
             hint = function() return account.status() end},

        }
        -- A claim is offered rather than demanded. The key it produces is
        -- shown on a card rather than in a row: it is twelve characters
        -- somebody has to copy onto another machine, and the value column of
        -- a list is the smallest place on the page to put it.
        if account.key ~= "" then
            rows[#rows + 1] = {label = "show my key", act = "show_key",
                hint = "shown once, and never written to this device"}
        elseif account.base ~= "" and not account.claimed then
            rows[#rows + 1] = {label = "keep this pilot", act = "claim",
                hint = "a key that brings this pilot back elsewhere"}
            rows[#rows + 1] = {label = "log in with a key", act = "enter_key",
                hint = "brings a claimed pilot back onto this device"}
        end
        if account.claimed and account.key == "" then
            if account.link_code ~= "" then
                rows[#rows + 1] = {label = "code", detail = account.link_code,
                    verbatim = true, act = "code",
                    hint = "type this on the other device within ten minutes"}
            else
                rows[#rows + 1] = {label = "add a device", act = "link",
                    hint = "shows a short code to type on the other device"}
            end
        end
        return rows
    end},

    -- Settings carry a `choice`, where a value sits along its range, as well
    -- as the word for it. The interface draws the range as steps and lights
    -- the one it is on, which says "two of three" in the shape of the thing
    -- rather than in a word that has to be read and compared against the word
    -- on the row above.
    --
    -- Sound and music count their steps from off rather than from their first
    -- value, so silence is an empty range: three boxes with nothing in them.
    -- Lighting a box for off is a control saying it is doing a little of
    -- something while doing none of it, and that is the state somebody sets
    -- deliberately and then comes back wondering about.
    settings = {rows = {
        {label = "sound", detail = function() return VOLUMES[M.volume][2] end,
         choice = function() return M.volume - 1, #VOLUMES - 1 end,
         act = "volume"},
        {label = "music", detail = function() return MUSICS[M.music][2] end,
         choice = function() return M.music - 1, #MUSICS - 1 end,
         act = "music"},
        {label = "frames", detail = function()
            if not M.can_cap then return "as the display asks" end
            return CAPS[M.cap][2]
        end, choice = function()
            if not M.can_cap then return nil end
            return M.cap, #CAPS
        end, act = "cap"},
        {label = "fullscreen", detail = "fill the screen", act = "fullscreen",
         hint = "locks the keyboard where it can, and ctrl becomes a gun"},
    }},

    -- The controls used to be a line of text across the bottom of the screen
    -- in every frame of every game. They are read once and never again, and
    -- on a phone they were laid over the thumbs, naming keys the device does
    -- not have while the controls it does have sat unexplained. A thing you
    -- consult belongs somewhere you go to consult it.
    -- On a keyboard the page draws the keyboard: ui.lua renders the board
    -- with the bound keys lit by function when `board` is set, and these
    -- rows are only ever read on a touchscreen, where the thumbs are the
    -- controls and the board would be a picture of keys the device has not
    -- got. The layout itself is decision 33: the original's keys where the
    -- browser permits them, the nearest safe key where it does not.
    help = {board = true, rows = {
        {label = "steer", detail = "left thumb: point where you want the nose"},
        {label = "fire", detail = "right pads: guns, then bombs"},
        {label = "charges", detail = "tap a charge pad to spend it"},
        {label = "who", detail = "tap a pilot on the scoreboard"},
    }},

    -- What this build is, rather than what the game is.
    --
    -- The page used to be six lines explaining energy and bounty, which is
    -- what `help` is for, and one build number at the bottom. Anybody who
    -- opens `about` in a game that updates several times a day wants to know
    -- which build they are looking at and what it is talking to, and that is
    -- the one question no other screen answers.
    about = {rows = function()
        local rows = {
            {label = "build", detail = function()
                -- get_config_string, not get_config: the short name went out
                -- of the engine two versions before the one we build with,
                -- and calling it threw inside a draw, which on this renderer
                -- means the frame is never flushed and the last one stays on
                -- the GPU. That is why `about` looked like a menu that did
                -- nothing rather than a page that crashed.
                return sys.get_config_string("project.version", "dev")
            end, verbatim = true,
            hint = "the commit this page was built from; + means it was dirty"},
            {label = "wire", detail = function()
                return "protocol " .. tostring(net.PROTOCOL)
            end, hint = "a zone speaking a different one refuses the join and says so"},
            {label = "engine", detail = function()
                return "defold " .. (sys.get_engine_info().version or "?")
            end},
            -- The drawable, and what the hardware says it is covering. Set
            -- by the arena every frame from the page's own measurements.
            {label = "screen", detail = function()
                local s = M.screen
                if not s then return "?" end
                return string.format("%dx%d @%g  safe %g %g %g %g  %s",
                                     s.w, s.h, s.d, s.l, s.r, s.t, s.b,
                                     s.app and "app" or "tab")
            end, verbatim = true,
            hint = "drawable, density, the insets left right top bottom, "
                .. "and whether this is a home-screen app or a tab"},
            -- What the page believes about the screen it is on, in CSS
            -- points, unreduced. The canvas is sized from the first two and
            -- a phone has already been seen handing back a canvas the top
            -- inset short of its own screen; whether that missing strip is
            -- above the canvas or below it is the difference between a rail
            -- on the bottom edge and a rail floating over one, and no
            -- machine here can be asked.
            {label = "viewport", detail = function()
                local s = M.screen
                if not s or not s.vl then return "?" end
                return string.format(
                    "%g %g %g %g %g @%g",
                    s.vl, s.vv, s.vi, s.vo, s.vs, s.vt)
            end, verbatim = true,
            -- Bare numbers because the labelled version ran under the row's own
            -- label on a phone, which is the width this page has.
            hint = "heights in points: layout, visual, inner, outer, "
                .. "screen, and where the window sits on the screen"},
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

-- One row of a page, flattened for drawing: everything a live value gets
-- asked for its answer, and everything else copied across.
--
-- Two callers, and that is why this is a function. The stage draws the page
-- you are inside, and it also draws a preview of the page the rail stop under
-- the cursor leads to, so a row is flattened in two places. They were two
-- lists of fields, and the second one had been written before the spectate
-- cell existed and never learned about `figure`. What that looked like was a
-- cell whose figure changed depending on how you had arrived at the page: the
-- helmet once the cursor was in the grid, an Apex while it was still on the
-- rail, since a cell naming no figure falls back to hull zero.
local function view_row(r, i)
    local d = r.detail
    if type(d) == "function" then d = d() end
    local ci, cn
    if r.choice then ci, cn = r.choice() end
    return {
        label = r.label, detail = d, note = r.note, waiting = r.waiting,
        -- Whether this row's value is a string to be quoted rather than a
        -- word to be said, and whether its label is somebody's name. See the
        -- key on the pilot page and the sides on the team page.
        verbatim = r.verbatim, named = r.named,
        -- The side this row stands for, so the renderer can write it in that
        -- side's colour. The byte rather than the colour: which side counts
        -- as yours is the camera's business, and the camera is ui.lua's.
        tint = r.tint,
        index = i,
        -- `hull` names a ship to draw and `figure` overrides it with something
        -- that is not one.
        hull = r.hull, figure = r.figure, role = r.role,
        players = r.players, bots = r.bots, live = r.live,
        choice = ci, choices = cn,
        pick = (r.go or r.act) ~= nil,
        mark = r.mark and r.mark() or false,
    }
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
        -- Opened on the games, the page the client itself opens on, with the
        -- cursor in the list rather than on the rail. Escape mid-fight is
        -- somebody looking for another game as often as it is anything else,
        -- and the rail is one press to the left of it either way.
        M.show("zones")
        M.note = nil
    end
    return M.open
end

-- The acts this file settles on its own: they change something the menu owns
-- and nothing outside it has to hear about them. Anything else is handed back
-- to the arena by name.
--
-- Out here rather than inline in `activate` because an answer to a question
-- settles the same way a row does. Rolling a call sign is now a question, and
-- the answer that rolls one has to land where the row that used to would have,
-- not travel out to the arena and back for something the menu can do itself.
local function settle(act)
    if act == "reroll" then
        M.reroll()
    elseif act == "claim" then
        account.claim(function(ok)
            if not ok then M.note = account.note return end
            M.show_key()
        end)
    elseif act == "enter_key" then
        M.ask_key()
    elseif act == "paste" then
        -- Started here, picked up in `tick`: the browser answers a clipboard
        -- read on its own schedule and this engine's bridge does not wait.
        clip.ask()
        M.pasting = 2.0
        return "pasting"
    elseif act == "show_key" then
        M.show_key()
    elseif act == "copy" then
        clip.copy(M.ask and M.ask.code or account.key)
        -- The card stays up. A card that vanishes on copy is a card that ate
        -- the thing somebody was reading.
        M.confirm("Copied to the clipboard.",
                  {{label = "copy", act = "copy"},
                   {label = "done", act = "key_seen"}}, account.key)
    elseif act == "key_seen" then
        -- Off the screen and out of memory. It was never written to disk: a
        -- key kept beside the secret it protects is a second copy of the same
        -- thing.
        account.key = ""
    elseif act == "link" then
        -- The code arrives from the meta-layer a moment later, and the moment
        -- it does it is the only thing on this page worth looking at.
        account.link(function(ok)
            if not ok then M.note = account.note return end
            M.show_code()
        end)
    elseif act == "code" then
        -- The row that holds it, pressed again. Answering the card never
        -- clears the code: it is live for ten minutes whatever this screen is
        -- showing, and somebody who dismissed it and walked to the other
        -- machine should not have to make a second one.
        M.show_code()
    elseif act == "volume" then
        M.volume = M.volume % #VOLUMES + 1
        M.apply_settings()
        M.save_identity()
    elseif act == "music" then
        M.music = M.music % #MUSICS + 1
        M.apply_settings()
        M.save_identity()
    elseif act == "cap" then
        M.cap = M.cap % #CAPS + 1
        M.apply_settings()
        M.save_identity()
    else
        return act
    end
    return nil
end

-- Raise a question. `keys` is the answers in the order they are drawn, each a
-- label and the action answering it returns, and the last of them is the one
-- that changes nothing: it is where the cursor starts and what escape gives,
-- so a question can always be got out of by the key that gets out of anything.
-- `code` is a string the question is about rather than something it says: a
-- link code is read off this screen and typed into another machine, so it is
-- drawn large and in its own case, and the heading above it is the sentence.
function M.confirm(head, keys, code)
    M.ask = {head = head, keys = keys, sel = #keys, code = code}
end

-- The key, as big as it can be drawn, with the clipboard offered beside it
-- where there is one. Shown once: it is never written to disk, because a key
-- kept beside the secret it protects is a second copy of the same thing.
function M.show_key()
    if account.key == "" then return end
    local keys = {}
    if clip.have() then keys[#keys + 1] = {label = "copy", act = "copy"} end
    keys[#keys + 1] = {label = "done", act = "key_seen"}
    M.confirm("Write this down. It is the way back in.", keys, account.key)
end

-- Ask for a key. The card carries twelve empty slots, and what fills them is
-- a keyboard where there is one, the clipboard where there is one, and the
-- alphabet drawn under the slots where there is neither.
function M.ask_key()
    local keys = {}
    if clip.have() then keys[#keys + 1] = {label = "paste", act = "paste"} end
    keys[#keys + 1] = {label = "cancel"}
    M.ask = {head = "Type your key", keys = keys, sel = #keys,
             entry = {typed = "", n = KEY_LEN, alphabet = KEY_CHARS}}
end

-- One character into the slots, from whichever hand. Anything the alphabet
-- does not contain is dropped rather than shown: a key has no lowercase and no
-- dashes to type, so a hand that types them is not making a mistake worth
-- reporting.
function M.type_key(ch)
    local e = M.ask and M.ask.entry
    if not e or e.sending or #e.typed >= e.n then return false end
    ch = string.upper(ch or "")
    if #ch ~= 1 or not string.find(KEY_CHARS, ch, 1, true) then return false end
    e.typed = e.typed .. ch
    if #e.typed >= e.n then M.send_key() end
    return true
end

-- And one back out.
function M.rub_key()
    local e = M.ask and M.ask.entry
    if not e or e.sending or e.typed == "" then return false end
    e.typed = string.sub(e.typed, 1, #e.typed - 1)
    return true
end

-- A full set of slots, sent. The answer comes back on the account layer's own
-- schedule, so the card stays up saying so rather than closing on a promise.
function M.send_key()
    local e = M.ask and M.ask.entry
    if not e or #e.typed < e.n then return end
    e.sending = true
    M.ask.head = "Signing in"
    account.redeem_key("VW" .. e.typed, function(ok)
        if ok then
            M.ask = nil
            M.note = nil
            M.adopt_account_name()
            return
        end
        -- Wrong key, or a meta-layer that did not answer. Either way the slots
        -- empty and the card stays, because the next thing anybody does is try
        -- again.
        if M.ask and M.ask.entry then
            M.ask.entry.typed = ""
            M.ask.entry.sending = false
            M.ask.head = "That key was not recognised"
        end
    end)
end

-- Whatever the clipboard had, filtered to what a key is made of. A player who
-- copied the whole line, dashes and prefix and all, gets what they meant.
function M.paste_key(text)
    local e = M.ask and M.ask.entry
    if not e or e.sending or not text then return false end
    local out = ""
    for ch in string.gmatch(string.upper(text), ".") do
        if string.find(KEY_CHARS, ch, 1, true) then out = out .. ch end
    end
    -- The prefix is not part of the secret and is not typed, so a paste that
    -- carries it drops it rather than filling two slots with it.
    out = string.gsub(out, "^VW", "")
    if out == "" then return false end
    e.typed = string.sub(out, 1, e.n)
    if #e.typed >= e.n then M.send_key() end
    return true
end

-- The device code, as big as it can be drawn. Raised when one arrives and
-- again whenever its row is pressed.
function M.show_code()
    if account.link_code == "" then return end
    M.confirm("Type this on the other device", {{label = "done"}},
              account.link_code)
end

-- Answer the one that is up, and hand back what that answer is worth. Cleared
-- before the action is returned, so whatever acts on it is acting with the
-- question already down.
-- The answers that do something to the card rather than to the question:
-- copying what is on it and pasting into it both leave it standing, because
-- neither is an answer, they are hands reaching past the words.
local STAY = {copy = true, paste = true}

local function answer(i)
    local k = M.ask and M.ask.keys[i]
    if not k or not k.act then
        M.ask = nil
        return nil, true
    end
    if STAY[k.act] then return settle(k.act), true end
    M.ask = nil
    return settle(k.act), true
end

function M.click_answer(i)
    return answer(i)
end

-- Open the menu at a particular level, which is what a failed connection
-- wants: the reason belongs next to the thing that would fix it.
function M.show(...)
    M.stack = {"root"}
    for _, id in ipairs({...}) do M.stack[#M.stack + 1] = id end
    M.open = true
    M.hover = nil
    M.ask = nil
    -- The games list works out where its cursor belongs the next time it is
    -- looked at, so opening on it has to let it ask again.
    zone_synced = false
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
    M.hover = nil
    -- A question belongs to the panel it was asked in. Left standing, it would
    -- be waiting on the next thing to open the menu, which is a player pressing
    -- escape mid-fight and being asked something they have forgotten.
    M.ask = nil
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

-- Escape, from anywhere in here.
--
-- Over a game it shuts the panel and puts you back in the fight, whatever
-- level you are on. One press put the menu up, so one press has to take it
-- down: the menu opens on the games rather than at the root now, and walking
-- back out a level at a time made leaving cost three presses where it used to
-- cost two. Left is still what walks back through the tree.
--
-- With nothing behind the panel there is nothing to shut it onto, so escape
-- walks back like left does and means at the root what it always meant.
local function escape()
    if M.close() then return nil, true end
    return back()
end

-- Put the cursor on the game you were in last, once the directory has
-- answered. Called by the arena rather than worked out during a draw, because
-- the list arrives on its own schedule and moving a selection out from under a
-- player mid-frame is exactly the surprise the stack reset above exists to
-- stop.
--
-- The cursor is the whole of it. A row of this list used to carry a mark as
-- well, a lit wedge and a lit name on the game you were in, which is a second
-- thing to read saying what the cursor already sits on, and on a list of three
-- games two of them were the answer to different questions.
function M.tick(dt)
    -- A clipboard read started a moment ago, answered whenever the browser
    -- gets round to it. Given up on after a couple of seconds rather than
    -- polled for ever: a refused read never answers at all.
    if M.pasting then
        M.pasting = M.pasting - (dt or 0)
        local text = clip.take()
        if text then
            M.pasting = nil
            M.paste_key(text)
        elseif M.pasting <= 0 then
            M.pasting = nil
        end
    end
    if M.at() ~= "zones" then
        zone_synced = false
        -- And forget where the cursor was. Every other page is a place you
        -- left off; this one has a right answer, and it is the game you are in
        -- rather than the row you were reading when you walked away.
        M.sel.zones = nil
        return
    end
    if zone_synced or #directory.rows == 0 then return end
    zone_synced = true
    -- Never over a cursor somebody has already moved. The client opens on this
    -- list now, so a player can be arrowing down it while the directory is
    -- still being asked, and a row that jumps out from under them a second
    -- later is worse than one that never moved.
    if M.sel.zones and M.sel.zones > 1 then return end
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
    -- No page here is named. The rail is lit at the stop you are inside and
    -- carries the word for it, so a title over the stage would be the same
    -- answer written twice.
    local out = {depth = #M.stack, sel = sel,
                 -- What the page has to say when it has nothing to list.
                 empty = nd.empty and nd.empty() or nil,
                 -- The question, if one is up. Everything else in the view is
                 -- still filled in: the panel is drawn and then stood down
                 -- under it, rather than replaced by it.
                 ask = M.ask,
                 -- The hull you are in, so the rail can draw it as its mark.
                 class = M.class,
                 -- Whether there is anything to shut, which is whether there
                 -- is a game behind the panel. It used to say "or you are a
                 -- level in", because the same control did the going back as
                 -- well; the rail does that from every level now, and this is
                 -- only the way out.
                 note = M.note, closable = not M.home,
                 -- Whether there is a game behind the panel, which is what
                 -- decides where the block sits: clear of the corner stack
                 -- over an arena, centred over the starfield. Not whether you
                 -- are at the top of the menu. It used to say both at once,
                 -- and so the whole block moved every time you went a level
                 -- in: on a phone held sideways the rail slid 124 points out
                 -- from under the thumb that had just tapped it, and the next
                 -- tap hit nothing.
                 home = M.home,
                 -- The help page asks for the drawn keyboard; whether the
                 -- device gets one is ui.lua's call, since only it knows
                 -- whether there is a keyboard to draw a picture of.
                 board = nd.board or false,
                 rows = {}}
    for i, r in ipairs(rows) do
        out.rows[i] = view_row(r, i)
    end
    -- The sentence about whatever is under the cursor, drawn once under the
    -- list rather than squeezed onto every row.
    local cur = rows[sel]
    out.hint = cur and cur.hint or nil
    -- A hint may be a function, for the ones that describe something that
    -- moves: whether this pilot is signed in changes while the page is open.
    if type(out.hint) == "function" then out.hint = out.hint() end

    -- The destinations, always, whatever level the stack is at: the interface
    -- draws them as a rail of icons and the rail is the one thing on screen
    -- that does not move. Which of them you are inside is `rail_sel`, and at
    -- the root that is simply the row the cursor is on.
    local top = rows_of(NODES.root)
    out.rail = {}
    for i, r in ipairs(top) do
        local d = r.detail
        if type(d) == "function" then d = d() end
        out.rail[i] = {label = r.label, icon = r.icon or "about",
                       detail = d, index = i}
    end
    if #M.stack == 1 then
        out.rail_sel = sel
        out.focus = "rail"
        -- The row a pointer is resting on. Only here: one level in the stage
        -- has the cursor, and a hover moves that cursor rather than lighting
        -- a second row beside it. At the root the cursor is on the rail, so
        -- the only thing that can say what a click would land on is the
        -- pointer itself.
        out.hover = M.hover
        -- What the destination under the cursor holds, drawn in the stage
        -- beside the rail rather than after a keystroke. Moving down a rail
        -- that shows you what each stop contains is one gesture; moving down
        -- a list of words and pressing enter to find out is two.
        local pick = top[sel]
        if pick and pick.go and NODES[pick.go] then
            local nd2 = NODES[pick.go]
            out.board = nd2.board or false
            out.empty = nd2.empty and nd2.empty() or nil
            out.rows = {}
            for i, r in ipairs(rows_of(nd2)) do
                out.rows[i] = view_row(r, i)
            end
            out.hint = nil
            -- Nothing in the preview is selected, because the cursor is on
            -- the rail. `sel` at this level counts rail stops, and left where
            -- it was it lit whichever stage row happened to share that
            -- number: standing on `ship` put a cursor on the second hull.
            -- What stays lit is the marked row, which is the hull you are
            -- flying or the game you are in, and that is a fact rather than
            -- a cursor.
            out.sel = 0
        else
            -- A stop that acts rather than descends. Nothing on the rail
            -- does today, but the branch stays: the stage says what the stop
            -- will do rather than drawing an empty panel.
            out.rows = {}
            out.hint = pick and (pick.hint or pick.detail) or nil
            if type(out.hint) == "function" then out.hint = out.hint() end
        end
    else
        out.focus = "stage"
        -- Which rail stop this level lives under, so the icon stays lit while
        -- you are inside it.
        local id = M.stack[2]
        for i, r in ipairs(top) do
            if r.go == id then out.rail_sel = i end
        end
    end
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
    elseif r.act == "reroll" then
        -- The one row on the pilot page that throws something away. A call
        -- sign is the only name anybody has here, it is the name on the
        -- scoreboard of every game this pilot has flown, and the row that
        -- shows it used to replace it on the press with nothing said.
        M.confirm("your call sign is " .. M.name,
                  {{label = "roll", act = "reroll"}, {label = "keep"}})
        return nil
    elseif r.act == "join" then
        local pick = directory.rows[r.value]
        -- Likewise a request. Which address serves this game, and whether it
        -- answers, is the arena's business. Held before the question is asked
        -- as well as without one, since the answer that joins carries a word
        -- rather than a row.
        M.chosen = pick
        -- Every press on this list while you are in a game costs you the game
        -- you are in, so every one of them asks first. Not on the home screen,
        -- where there is nothing behind the panel to lose, and not on a game
        -- nothing is serving, which has its own answer already.
        if pick and not M.home and M.zone ~= "" then
            if pick.name == M.zone then
                -- The game you are already in. Joining it again is a
                -- disconnect and a handshake to arrive where you already are,
                -- so the press means the other thing it could mean. This is
                -- the whole of how a player leaves now: the list used to carry
                -- a "leave this game" row at its foot, a long way from the
                -- game it was about, in a list otherwise all places to go.
                -- Two answers, not three. Sitting out used to live here as a
                -- third, and it was in the wrong room: this card is about the
                -- game you are in, and watching is about what you are flying,
                -- which is the ship page's question. It is the ninth cell
                -- there now.
                M.confirm((M.watching and "you are watching "
                           or "you are already flying ") .. pick.name,
                          {{label = "leave", act = "leave"},
                           {label = "stay"}})
                return nil
            elseif pick.live then
                M.confirm("leave " .. M.zone .. " for " .. pick.name .. "?",
                          {{label = "switch", act = "join"},
                           {label = "stay"}})
                return nil
            end
        end
        return "join"
    end
    return settle(r.act)
end

-- keys: {left, right, up, down, go, back} as booleans, already edge-detected
-- by the arena script: a tap can go down and up inside one frame and never
-- appear in the key state that flight reads.
--
-- Returns an action name or nil, and whether anything moved, so the caller
-- can make a noise about it.
function M.step(keys)
    if not M.open then return nil, false end

    -- A question owns the keys while it is up, which is the whole of what
    -- makes it a question rather than a notice: the list underneath cannot be
    -- walked, and nothing behind it can be pressed by accident.
    if M.ask then
        local n = #M.ask.keys
        -- Backspace belongs to the slots when there are slots.
        if keys.rub and M.rub_key() then return nil, true end
        -- Escape is the last answer, which is the one that changes nothing.
        if keys.back then return answer(n) end
        if keys.left or keys.up then
            M.ask.sel = (M.ask.sel - 2) % n + 1
            return nil, true
        end
        if keys.right or keys.down then
            M.ask.sel = M.ask.sel % n + 1
            return nil, true
        end
        if keys.go then return answer(M.ask.sel) end
        return nil, false
    end

    local id = M.stack[#M.stack]
    -- Built once. A node's rows may be a function, and asking it three times
    -- to move a cursor one row is three lists allocated to answer one
    -- keystroke.
    local nd = node()
    local rows = rows_of(nd)
    local n = #rows

    -- A page can hold nothing at all: the games, before a directory has
    -- answered. Escape and left still work; there is no row for anything else
    -- to move to, and a cursor stepped round a list of none is a nan.
    if n == 0 then
        if keys.back then return escape() end
        if keys.left then return back() end
        return nil, false
    end

    -- A grid reads its own arrows. Everywhere else right is enter, which is
    -- what a one-column list wants and exactly wrong on a page laid out in
    -- four: pressing right to look at the hull beside this one flew it
    -- instead, and down, which should have gone to the row below, went one
    -- ship to the right. Enter is still the only thing that picks.
    if nd.grid and #M.stack > 1 and n > 0 then
        local cols = math.max(1, math.min(M.cols, n))
        local i = row_index(rows)
        if keys.back then return escape() end
        -- The edges wrap, along the row for right and through the list for up
        -- and down, so nothing on this page is out of reach in one press.
        --
        -- Left off the first column is the exception, because left is the way
        -- out on every other page and this page has to have one: wrapped
        -- round to the far end of the row it shut the door, and a hand on the
        -- arrows alone could not get back to the rail.
        local first = i - (i - 1) % cols
        local last = math.min(first + cols - 1, n)
        if keys.left then
            if i == first then return back() end
            M.sel[id] = i - 1
            return nil, true
        end
        if keys.right then
            M.sel[id] = (i < last) and (i + 1) or first
            return nil, true
        end
        if keys.up then
            M.sel[id] = (i - 1 - cols) % n + 1
            return nil, true
        end
        if keys.down then
            M.sel[id] = (i - 1 + cols) % n + 1
            return nil, true
        end
        if keys.go then return activate(), true end
        return nil, false
    end

    if keys.back then return escape() end
    if keys.left then return back() end

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

-- A pointer landed on the rail, which names a destination whatever level the
-- stack is at. That is the whole difference between it and a row: the rail
-- does not belong to the page you are looking at, so a tap on it has to go
-- home before it goes anywhere.
--
-- It used to be routed as a row, which was right when the menu was one list
-- and the root's rows were the destinations. With a rail on screen at every
-- level it meant that once you were inside a page the rail stopped
-- navigating: a tap on `settings` from inside `ship` picked the fourth hull.
-- On a phone, where the rail is the only way to move, that is the whole of
-- navigation not working.
-- Which stop the panel is currently inside, or nil at the root, where the
-- stage is a preview of the stop under the cursor rather than the stop
-- itself. Worked out the way the view works it out.
local function rail_inside()
    if #M.stack < 2 then return nil end
    for i, r in ipairs(rows_of(NODES.root)) do
        if r.go == M.stack[2] then return i end
    end
    return nil
end

function M.click_rail(index)
    if not M.open then return nil, false end
    -- The lit stop, tapped while you are already in it, with a game behind
    -- the panel: that is the way back to the game. A phone's rail is the
    -- whole of its navigation and there is no outside to press, so without
    -- this the only way out is one small x; and re-entering the page you are
    -- already reading is the one thing a rail stop could do that is nothing.
    --
    -- At the root the same stop is lit while the stage only previews it, and
    -- there the tap goes in, which is what it has always done.
    if index == rail_inside() and M.close() then return nil, true end
    M.stack = {"root"}
    M.sel.root = index
    M.note = nil
    return activate(), true
end

-- A pointer came to rest on a row of the stage, or on none. It moves the
-- cursor, which is what up and down do, so the two hands are driving one
-- highlight rather than lighting a row each.
--
-- Only on a change. A pointer left lying on a row would otherwise put the
-- cursor back on it every frame, and the arrow keys would not be able to
-- leave the row the mouse happens to be over.
--
-- Reports whether it landed somewhere, so the caller can make the same noise
-- a key does. Leaving a row is silent: there is nothing to say about it.
function M.hover_stage(index)
    if index == M.hover then return false end
    M.hover = index
    -- At the root the cursor belongs to the rail and the stage is a preview,
    -- so a hover there is drawn rather than moved. One level in, the stage has
    -- the cursor and this is that cursor.
    if index and M.open and #M.stack > 1 then
        local rows = rows_of(node())
        if rows[index] then M.sel[M.stack[#M.stack]] = index end
    end
    return index ~= nil
end

-- A pointer landed on a row of the stage, which is not always a row of the
-- node the cursor is in: on the home screen the stage shows what the rail is
-- pointing at, before anybody has gone in. So this goes in first and then
-- acts, which is what the tap meant.
function M.click_stage(index)
    if not M.open then return nil, false end
    if #M.stack == 1 then
        local top = rows_of(node())
        local r = top[row_index(top)]
        if not (r and r.go) then return nil, false end
        M.stack[#M.stack + 1] = r.go
        M.note = nil
    end
    local id = M.stack[#M.stack]
    M.sel[id] = index
    return activate(), true
end

-- A pointer landed on a row the interface published.
function M.click(index)
    if not M.open then return nil, false end
    M.sel[M.stack[#M.stack]] = index
    return activate(), true
end

-- The x on the panel. It shuts the menu rather than stepping back a level,
-- which is what a cross means everywhere else, and it is drawn only where
-- there is a game behind to shut it onto.
function M.click_close()
    if not M.open then return nil, false end
    return nil, M.close()
end

return M
