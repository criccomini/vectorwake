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
local install = require("arena.install")
local sfx = require("arena.sfx")
local controls = require("arena.controls")

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
-- And which of its rooms, by the number the server gave that room, when a row
-- named one. Nil is what every arrival through the games list says, and it
-- means "wherever the fill ladder puts me".
M.chosen_room = nil
M.stack = {"root"}
M.sel = {}              -- selected row, per node, so a level remembers
M.hover = nil           -- the stage row a pointer is resting on
M.rail_hover = nil      -- and the rail stop, which works the same way
M.note = nil            -- set by the arena when a connection fails
M.screen = nil          -- the drawable and its insets, for the about page

-- A question the menu wants answered before it will do anything else, and
-- nothing while there is none. Whoever raises it fills in the words and what
-- each answer is worth; this file knows only that the last answer is the one
-- that changes nothing, which is the one escape gives.
--
-- A question may carry `fields`: lines of type a person fills in before
-- answering, each a label, what has been typed, and whether it is drawn as
-- discs rather than said. `field` is which of them the next character lands
-- in. The one card that asks for typing is the account card, and it is the
-- only typing in the game.
M.ask = nil             -- {head, keys = {{label, act}}, sel, fields, field}

-- What a typed line may hold: the arena's own rule for a name, printable
-- ASCII and a space, and the server's sizes. A password takes anything
-- typeable because it is never shown or spoken, only hashed.
local NAME_MAX = 24
local PASSWORD_MAX = 64
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
-- None of this is typed. The name is generated, so arriving costs no
-- keyboard, and a console will hand us the platform's own name when we get
-- there. The directory is configuration rather than input: the zones list asks
-- it what is running and the player picks from the answer.
--
-- There is deliberately no address field. A game whose front door is a text
-- box asking for a websocket URL is a game with a text box in it, and the
-- machinery under one, an invisible DOM input over the canvas with focus
-- handed back and forth and enter delivered to whichever of the two had the
-- caret, was the single largest source of bugs in this client.
--
-- The account card does ask for typing, and in a browser the page holds those
-- lines as input elements (decision 37). It is not the same bargain: they are
-- visible, they take their own click, and they are there only while the card
-- is. The one piece of focus this client moves on anybody's behalf is the
-- caret into the first line as a card comes up, and it hands it straight back
-- to the canvas when the card goes.
-- Where the community is. The Caddy redirect rather than the invite itself,
-- so an invite that has to be reissued is one line of configuration and not a
-- client release every open tab is behind. The rail row carries it for the
-- page to lay a link over, and `activate` opens it where there is no page.
local DISCORD = "https://play.vectorwake.net/discord"

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

-- A fresh call sign. The server's draw when there is a server, because the
-- name is unique fleet-wide and only the holder of the pool can promise
-- that; the local generator survives for a deployment with no meta-layer,
-- where there is nobody to be unique against.
--
-- The card that asked stays up while the draw is in flight and turns into the
-- refusal when there is one, the same as the account cards do. This used to
-- take `ok` alone and drop the reason on the floor, which mattered because
-- there is a reason worth reading: the server caps rerolling per address per
-- hour, and a player enjoying the names reaches that cap. Past it the row
-- simply stopped changing and said nothing about why, because the sentence
-- landed on `account.note` while this file draws its own `M.note`, which only
-- a failed join ever writes to.
function M.reroll(asked)
    if not account.online() then
        M.name = callsign.generate()
        M.save_identity()
        return
    end
    if asked then
        M.ask = asked
        asked.sending = true
        asked.head = "Rolling."
    end
    account.rename(function(ok, why)
        -- Whether the card that asked is still the one up. A reply for a card
        -- the player has since dismissed has nobody to tell, but a name it
        -- already won is still ours to take.
        local mine = asked ~= nil and M.ask == asked
        if ok then
            if mine then M.ask = nil end
            M.adopt_account_name()
            return
        end
        if mine then
            asked.sending = false
            asked.head = (why or "That did not work.") .. "."
            asked.head = string.gsub(asked.head, "%.%.$", ".")
        end
    end)
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
-- carry a `note`, which is a sentence drawn in the row itself, under its
-- name, whether or not the cursor is on it.
--
-- There was a `hint` as well: a sentence about the selected row, drawn once at
-- the foot of the panel. Every row on about, pilot and settings had one, and
-- they were captions. "The commit this page was built from" under a row
-- labeled build with a commit in it. "Shown once, and never written to this
-- device" under show my key. A caption is read once, and after that it is a
-- line of text moving about at the bottom of the page every time the cursor
-- moves.
--
-- The last of them said whether a side would let you in, which was a fact
-- rather than a caption, and it went too: a mechanism kept alive for one row
-- is a mechanism the next row will use for a caption. What a row has to say
-- it says on the row. The foot of the panel is left for `note` on the view,
-- which is why a join failed, and that is the other kind of sentence
-- entirely: something that just happened rather than a label on something
-- sitting still.
--
-- A node's `rows` is a table, or a function returning one when what is in the
-- list depends on the moment.

local HULLS = {
    {"Apex", "interceptor", "fastest, sharpest turn, lightest bar"},
    {"Wedge", "bomber", "heavy bombs on a short reload"},
    {"Chord", "skirmisher", "quick guns, no bomb rack"},
    {"Anvil", "heavy", "the biggest bar and the biggest bomb"},
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
        rows[#rows + 1] = {
            -- Somebody named this side, so it is drawn the way they named it
            -- rather than the way this interface says its own words.
            label = t.name, named = true,
            -- And in the color that side wears on every plate in the arena,
            -- so this list is where the colors get their names. Yours is
            -- cyan here as it is everywhere: `tint` is the byte, and ui.lua
            -- decides what "yours" means, since it is the side the camera is
            -- behind rather than the one this menu belongs to.
            tint = t.team,
            detail = t.bots > 0 and (t.humans .. " + " .. t.bots .. " AI")
                or tostring(t.humans),
            act = "team", value = t.team,
            mark = function() return t.team == net.my_team end,
        }
    end
    -- A side of your own, when the room may hold another. A zone whose
    -- max_teams is the count of its own sides never offers this, which is how
    -- a flag round says there is no third side to be.
    if net.may_found then
        rows[#rows + 1] = {label = "new team", detail = "yours",
                           act = "found"}
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
-- sentence about what the game actually is goes under the name as a note. Both
-- on one line was tried: "everybody against everybody" beside "3 playing, 5
-- AI" is 45 characters against the 40 a phone has room for, and the count is
-- what decides while the description is what explains. It sat at the foot of
-- the panel for a while as well, a long way from the name it belonged to,
-- which made choosing between three games into reading three sentences one at
-- a time.
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
            -- The one stop that leaves. Every other row on this rail opens a
            -- page of the game's own; this hands the browser somewhere else,
            -- which is why it sits at the bottom next to the row that says
            -- what the game is rather than up among the ones you fly with.
            {label = "discord", icon = "discord", detail = "chat with us",
             act = "discord", link = DISCORD},
            {label = "about", icon = "about", go = "about"},
        }
        -- Sides are a thing a room has, so the row appears with the room and
        -- says which one you are on. On the home screen there is no room and
        -- nothing to be on.
        if not M.home and #net.teams > 0 then
            table.insert(rows, 4, {label = "team", icon = "team",
                detail = function() return net.my_team_name() end,
                go = "teams"})
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
            {label = "call sign", detail = function() return M.name end,
             -- A call sign is upper, lower and numeric as its owner has it.
             verbatim = true, act = "reroll"},
        }
        -- A password is offered rather than demanded, and it is the whole
        -- account model: set one and this name is yours anywhere, skip it
        -- and the pilot lives on this device until a quiet week reclaims
        -- it. No rows at all without a meta-layer, because then there is
        -- nothing behind them to talk to.
        if account.base ~= "" and not account.claimed then
            rows[#rows + 1] = {label = "keep this pilot", act = "claim",
                note = "a password brings this pilot back anywhere"}
            rows[#rows + 1] = {label = "log in", act = "enter_login",
                note = "call sign and password"}
        elseif account.claimed then
            rows[#rows + 1] = {label = "change password", act = "claim"}
            rows[#rows + 1] = {label = "log out", act = "logout",
                note = "this device becomes a fresh guest"}
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
    settings = {rows = function()
        local rows = {
            {label = "sound",
             detail = function() return VOLUMES[M.volume][2] end,
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
            {label = "fullscreen", detail = "fill the screen",
             act = "fullscreen"},
        }
        -- Only where there is somewhere to add it to and it is not there
        -- already. A row offering to install an app you are running inside is
        -- a row that makes the menu look like it is not paying attention.
        --
        -- The detail column carries the difference between the two ways in,
        -- since a tap and a trip through the share sheet are not the same
        -- offer. It used to be said again underneath in a hint, along with
        -- what an installed page is for, and that was a caption.
        local how = install.state()
        if how == "tap" then
            rows[#rows + 1] = {label = "add to home screen",
                               detail = "one tap", act = "install"}
        elseif how == "share" then
            rows[#rows + 1] = {label = "add to home screen",
                               detail = "how to", act = "install"}
        end
        return rows
    end},

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
    -- Built from arena/controls.lua rather than written out here, which is
    -- what these rows used to be. Two hand-kept lists of the same facts drift,
    -- and these did: they were describing a game with no map on the dial and
    -- nobody riding anybody, months after both landed. A row with no `pad` is
    -- a control a thumb cannot work and is left out rather than named.
    help = {board = true, rows = function()
        local rows = {}
        for _, c in ipairs(controls) do
            if c.pad then
                rows[#rows + 1] = {label = string.lower(c.name),
                                   detail = c.pad}
            end
        end
        return rows
    end},

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
            end, verbatim = true},
            -- Which of the two doors this connection came through, and what
            -- that door is made of. The difference is worth a line because
            -- it is the difference a player feels on a bad link: QUIC loses
            -- a packet and delays only that packet, TCP loses one and holds
            -- everything behind it. See docs/architecture/networking.md.
            --
            -- No address in any of these. Whoever runs the fleet reads logs;
            -- a player reading a wss url is reading something not addressed
            -- to them, which is the same call the empty games list makes.
            {label = "wire", detail = function()
                local t = net.transport()
                if t.kind == "wt" then
                    return "webtransport, quic datagrams"
                end
                if t.kind == "ws" then
                    local how = t.secure and "websocket, tls over tcp"
                        or "websocket, cleartext tcp"
                    -- Why this pilot is on the slower door, but only when
                    -- there was a faster one to miss: a zone that advertises
                    -- no door at all is not a network that ate anything.
                    --
                    -- And which of the two ways it happened, because they
                    -- want different things looked at. A dial that went
                    -- unanswered just now points at the network; a dial this
                    -- join never made points at the one before it, and
                    -- reading the first for the second sends somebody to
                    -- interrogate a firewall about packets nobody sent.
                    if t.refused and t.offered then
                        if t.tried then
                            return how .. " (quic did not answer)"
                        end
                        return how .. " (quic failed earlier, not retried)"
                    end
                    return how
                end
                -- Nothing is connected, so every answer here is about the
                -- next join rather than a live wire. Each one says so first:
                -- read quickly, "webtransport first, websocket behind it"
                -- looks like a reading off an instrument, and the one
                -- question this row exists to answer is which wire is
                -- carrying the game you are in.
                if t.trying then return "dialling webtransport" end
                if not t.able then return "not in a game, websocket only here" end
                -- The door of the last game this client tried, which is the
                -- only one it knows anything about. It used to say "on this
                -- network", which was the client believing that one silent
                -- door spoke for every other; it does not, and the next game
                -- gets its own dial.
                if t.refused then
                    return "not in a game, quic did not answer for that zone"
                end
                return "not in a game, webtransport first when you join"
            end},
            {label = "protocol", detail = function()
                return tostring(net.PROTOCOL)
            end},
            -- The browser's own account of a refused dial, verbatim, and only
            -- when there is one. A dial that simply timed out says nothing and
            -- this row stays away, which is itself the reading: silence means
            -- the packets left and none came back.
            --
            -- It earns a row because of where it is needed. The device most
            -- likely to be stuck on the slower door is a phone, and a phone is
            -- the one place a console cannot be opened without a cable and a
            -- second machine. This is that console, reduced to the one line
            -- worth having.
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
            end, verbatim = true},
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
            end, verbatim = true},
            {label = "zone", detail = function()
                if M.zone == "" then return "not in one" end
                return M.zone
            end},
            {label = "account", detail = function()
                if account.account and account.account > 0 then
                    return "#" .. tostring(account.account)
                end
                return "none yet"
            end},
        }
        -- The browser's own account of a refused dial, verbatim, and only
        -- when there is one. A dial that timed out has nothing to report and
        -- this row stays away, which is itself the reading: silence means the
        -- packets went out and none came back.
        --
        -- It earns a row because of where it is needed. The device most
        -- likely to be stuck on the slower door is a phone, and a phone is
        -- the one place a console cannot be opened without a cable and a
        -- second machine. This is that console, cut to the one line worth
        -- having.
        local why = net.transport().reason
        if why then
            -- Broken across rows rather than left to run off the side. A row
            -- lays a long detail out on a second line and does not wrap it
            -- again, so a browser's sentence ended at the screen edge with
            -- the informative half missing: the first attempt at reading one
            -- of these got as far as "undefined is not an object (evaluating
            -- 'wt" and stopped, which names nothing.
            local width = 40
            local first = true
            while #why > 0 do
                local cut = #why
                if cut > width then
                    -- Back up to a space so a word is not split, unless the
                    -- run has no space in it, which a stack trace often does
                    -- not: then take the hard cut and keep going.
                    cut = width
                    for i = width, math.floor(width / 2), -1 do
                        if string.sub(why, i, i) == " " then cut = i break end
                    end
                end
                rows[#rows + 1] = {label = first and "quic" or "",
                                   detail = string.sub(why, 1, cut),
                                   verbatim = true}
                why = string.gsub(string.sub(why, cut + 1), "^ +", "")
                first = false
            end
        end
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
        -- side's color. The byte rather than the color: which side counts
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
local function settle(act, asked)
    if act == "reroll" then
        M.reroll(asked)
    elseif act == "claim" then
        M.ask_password()
    elseif act == "enter_login" then
        M.ask_login()
    elseif act == "do_claim" then
        M.send_claim(asked)
    elseif act == "do_login" then
        M.send_login(asked)
    elseif act == "logout" then
        M.confirm("Log out of " .. M.name .. "?",
                  {{label = "log out", act = "do_logout"}, {label = "stay"}})
    elseif act == "do_logout" then
        account.logout()
        -- The fresh guest's name arrives on the account layer's schedule;
        -- until it does the old one would be a name this client no longer
        -- holds, so it goes now.
        M.name = ""
        M.save_identity()
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
-- that changes nothing: it is what escape gives, so a question can always be
-- got out of by the key that gets out of anything. On a plain question the
-- cursor starts there too; a card with fields starts on its first key, since
-- the whole point of raising one is to fill it in and send it.
function M.confirm(head, keys, code)
    M.ask = {head = head, keys = keys, sel = #keys, code = code}
end

-- The card that claims this pilot, and the one that changes the password
-- later, which are the same card with a different sentence over it: either
-- way the device secret vouches for you and a new password lands.
-- `kind` is what the line is for, in the words the web already has for it,
-- since on a browser these lines are real input elements and that word is
-- the whole of what tells a password manager which box is which. A card
-- asking for a new password names the pilot it belongs to as well: managers
-- file a password under a user name, and this card has no line for one
-- because the name is not in question here.
function M.ask_password()
    local head = account.claimed and "Choose a new password."
        or ("Keep " .. M.name .. ". Choose a password.")
    M.ask = {head = head,
             keys = {{label = "keep", act = "do_claim"}, {label = "cancel"}},
             sel = 1, field = 1, ghost = M.name,
             fields = {{label = "password", value = "", mask = true,
                        kind = "new-password", max = PASSWORD_MAX}}}
end

-- The card that brings a claimed pilot onto this device.
function M.ask_login()
    M.ask = {head = "Log in.",
             keys = {{label = "log in", act = "do_login"}, {label = "cancel"}},
             sel = 1, field = 1,
             fields = {{label = "call sign", value = "", kind = "username",
                        max = NAME_MAX},
                       {label = "password", value = "", mask = true,
                        kind = "current-password", max = PASSWORD_MAX}}}
end

-- One character into the focused field, from the keyboard's text trigger.
-- Printable ASCII only, which is the same rule the server holds names to and
-- wide enough for any password worth having.
--
-- This is the path for a machine with keys. Where the client hands the lines
-- to the page as input elements, the elements hold the text and none of this
-- runs; `pull` below is how what was typed comes back.
-- Whether a card is waiting for characters. Any key that does something to
-- the game has to ask, because a key trigger and the text stream are separate
-- actions down here: a letter bound to a control reaches that control while it
-- is also being typed into a field.
function M.typing()
    local a = M.ask
    return (a and a.fields and a.fields[a.field or 1] and not a.sending) and true
        or false
end

function M.type_field(ch)
    local a = M.ask
    local f = a and a.fields and a.fields[a.field or 1]
    if not f or a.sending then return false end
    if type(ch) ~= "string" or #ch ~= 1 then return false end
    local b = string.byte(ch)
    if b < 32 or b > 126 then return false end
    if #f.value >= (f.max or NAME_MAX) then return false end
    f.value = f.value .. ch
    return true
end

-- And one back out.
function M.rub_field()
    local a = M.ask
    local f = a and a.fields and a.fields[a.field or 1]
    if not f or a.sending or f.value == "" then return false end
    f.value = string.sub(f.value, 1, #f.value - 1)
    return true
end

-- Whether the lines are the page's input elements rather than this module's
-- strings. Set by whoever publishes them, since only the client knows whether
-- there is a page under it, and read here at the one moment it matters.
M.dom = false

-- What the elements hold, back into the fields, at the moment the card is
-- sent. Not as it is typed: while they are up they are the text on screen,
-- and a value polled sixty times a second would be sixty crossings of a
-- bridge for an answer nobody is reading. One line each, in the order they
-- were published, which is the order the fields are in.
local function pull()
    local a = M.ask
    if not (M.dom and html5 and a and a.fields) then return end
    local ok, s = pcall(html5.run,
                        "window.vwAskRead ? window.vwAskRead() : ''")
    if not ok or type(s) ~= "string" or s == "" then return end
    local i = 1
    for v in string.gmatch(s .. "\n", "([^\n]*)\n") do
        if not a.fields[i] then break end
        a.fields[i].value = v
        i = i + 1
    end
end

-- A tap landing on one of the lines. Focus follows the finger.
function M.focus_field(i)
    local a = M.ask
    if not (a and a.fields and a.fields[i]) or a.sending then return false end
    if a.field == i then return false end
    a.field = i
    return true
end

-- The next line down, wrapping. Up is the same walk the other way.
function M.next_field(back)
    local a = M.ask
    if not (a and a.fields and #a.fields > 1) or a.sending then return false end
    local n = #a.fields
    a.field = ((a.field or 1) - 1 + (back and -1 or 1)) % n + 1
    return true
end

-- The claim, sent. The card stays up while the answer is in flight and turns
-- into the refusal when there is one, holding what was typed: the next thing
-- anybody does with a refused password is fix it, not retype it.
function M.send_claim(asked)
    local password = asked and asked.fields and asked.fields[1].value or ""
    M.ask = asked
    asked.sending = true
    asked.head = "One moment."
    account.claim(password, function(ok, why)
        if M.ask ~= asked then return end
        if ok then
            M.ask = nil
            return
        end
        asked.sending = false
        asked.head = (why or "That did not work.") .. "."
        asked.head = string.gsub(asked.head, "%.%.$", ".")
    end)
end

-- The login, likewise.
function M.send_login(asked)
    local name = asked and asked.fields and asked.fields[1].value or ""
    local password = asked and asked.fields and asked.fields[2]
        and asked.fields[2].value or ""
    M.ask = asked
    asked.sending = true
    asked.head = "Signing in."
    account.login(name, password, function(ok, why)
        if M.ask ~= asked then return end
        if ok then
            M.ask = nil
            M.note = nil
            M.adopt_account_name()
            return
        end
        asked.sending = false
        asked.head = (why or "That did not work.") .. "."
        asked.head = string.gsub(asked.head, "%.%.$", ".")
    end)
end

-- Answer the one that is up, and hand back what that answer is worth.
-- Cleared before the action is returned, so whatever acts on it is acting
-- with the question already down; the card itself travels into `settle`,
-- because the sending answers need what was typed into it, and the sends put
-- it back up themselves while the reply is in flight.
local function answer(i)
    local a = M.ask
    local k = a and a.keys[i]
    if a and a.sending then return nil, false end
    -- Whatever is in the boxes, before the card comes down and takes them
    -- with it. Cancel pulls too: it costs one crossing and it means the
    -- fields are always what the player last saw, whichever way out is
    -- taken.
    pull()
    if not k or not k.act then
        M.ask = nil
        return nil, true
    end
    M.ask = nil
    return settle(k.act, a), true
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
    M.rail_hover = nil
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
    M.rail_hover = nil
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
    -- Whether this can be added to a home screen, which the browser decides a
    -- second or two after the page loads rather than at the moment it is
    -- asked.
    install.tick(dt)
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
                 -- over an arena, centered over the starfield. Not whether you
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
    -- The destinations, always, whatever level the stack is at: the interface
    -- draws them as a rail of icons and the rail is the one thing on screen
    -- that does not move. Which of them you are inside is `rail_sel`, and at
    -- the root that is simply the row the cursor is on.
    --
    -- Which one a pointer is resting on goes with them, at every level. At
    -- the root it is the cursor and says nothing new; one level in it is the
    -- only thing on screen that says what a click would land on, which is the
    -- job it does for the stage on the home screen.
    out.rail_hover = M.rail_hover
    local top = rows_of(NODES.root)
    out.rail = {}
    for i, r in ipairs(top) do
        local d = r.detail
        if type(d) == "function" then d = d() end
        out.rail[i] = {label = r.label, icon = r.icon or "about",
                       detail = d, index = i, link = r.link}
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
    elseif r.act == "discord" then
        -- A new tab, and the game keeps running behind it: nothing here is
        -- paused, and a player who came to ask a question has not asked to
        -- leave the room they are in.
        --
        -- The redirect rather than the invite itself. `deploy/caddy` owns
        -- /discord and the site's own button points at the same path, so an
        -- invite that has to be reissued is one line of Caddy and not a
        -- client release that every open tab is behind.
        --
        -- Off the web, or from a key. In a browser the page keeps a real
        -- anchor over this stop, so a tap never arrives here at all: nothing
        -- the client does from its own loop is inside the gesture, and a tab
        -- opened outside one is what a popup blocker stops. Two attempts went
        -- that way first, sys.open_url and then an anchor clicked from Lua,
        -- and both worked on a desktop and were blocked on every phone.
        --
        -- The result is not checked. There is nothing better to do with a no,
        -- and asking is what put a card with the address on it up before.
        -- Only ever reached off the web, or from a key. In a browser the
        -- page has a real anchor over this stop and the tap never gets here.
        pcall(sys.open_url, DISCORD, {target = "_blank"})
        return nil
    elseif r.act == "install" then
        -- One tap where the browser allows one. Where it does not, the row
        -- says where the button is, which is all anybody needs and is what
        -- everybody who has ever installed one of these had to be told.
        if install.state() == "tap" then
            install.go()
            return nil
        end
        M.confirm("Tap the share button, then Add to Home Screen.",
                  {{label = "ok", act = "ok"}})
        return nil
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
        -- Backspace belongs to the fields when there are fields.
        if keys.rub and M.rub_field() then return nil, true end
        -- Escape is the last answer, which is the one that changes nothing.
        if keys.back then return answer(n) end
        -- On a card with lines to fill in, up and down walk the lines and
        -- left and right walk the answers; enter sends. On a plain question
        -- all four walk the answers, so arrows never do nothing.
        if M.ask.fields and (keys.up or keys.down) then
            if M.next_field(keys.up) then return nil, true end
            return nil, false
        end
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

-- The same thing for the rail, which is the same rule read the other way
-- round. A hover is always drawn; it moves the cursor only where the cursor
-- lives, and the cursor lives in the rail at the root and in the stage
-- everywhere below it. So resting on a stop at the root walks the rail and
-- brings its preview along, exactly as the arrows do, and resting on one
-- from inside a page lights it without taking the cursor off the list you
-- are reading.
function M.hover_rail(index)
    if index == M.rail_hover then return false end
    M.rail_hover = index
    if index and M.open and #M.stack == 1 then
        local top = rows_of(NODES.root)
        if top[index] then M.sel.root = index end
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
