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
local sfx = require("arena.sfx")

local M = {}

M.open = true           -- the page opens on it
M.home = true           -- no game behind the panel
M.class = 0             -- the hull you are flying, kept in step with the sim
M.pending = nil         -- the hull a row just asked for
M.chosen = nil          -- the game a row just asked for
M.stack = {"root"}
M.sel = {}              -- selected row, per node, so a level remembers
M.hover = nil           -- the stage row a pointer is resting on
M.note = nil            -- set by the arena when a connection fails
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
            label = r.name, detail = r.count,
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
    -- Leaving is not a destination, so it is not a stop on the rail: it is
    -- the last thing in the list of games, which is where you are when you
    -- are thinking about which game you are in. Only with one behind the
    -- panel, since on the home screen there is nothing to leave.
    if not M.home then
        rows[#rows + 1] = {label = "leave this game", act = "leave",
                           note = "back to the home screen"}
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
    root = {rows = function()
        local rows = {
            {label = "zones", icon = "zones", detail = function()
                if M.zone ~= "" then return M.zone end
                return "choose a game"
            end, go = "zones"},
            {label = "ship", icon = "ship",
             detail = function() return HULLS[M.class + 1][1] end,
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
    ship = {grid = true, rows = hull_rows()},

    zones = {rows = zone_rows},

    teams = {rows = team_rows},

    pilot = {rows = function()
        local rows = {
            -- What the account layer makes of you rides on the hint line
            -- rather than in a row of its own. It is a sentence, and a
            -- sentence in the value column of a row with no label floated in
            -- the middle of the panel attached to nothing.
            {label = "call sign", detail = function() return M.name end,
             act = "reroll",
             hint = function() return account.status() end},

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
    M.hover = nil
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
--
-- The cursor is the whole of it. A row of this list used to carry a mark as
-- well, a lit wedge and a lit name on the game you were in, which is a second
-- thing to read saying what the cursor already sits on, and on a list of three
-- games two of them were the answer to different questions.
local zone_synced = false

function M.tick()
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
        local d = r.detail
        if type(d) == "function" then d = d() end
        local ci, cn
        if r.choice then ci, cn = r.choice() end
        out.rows[i] = {
            label = r.label, detail = d, note = r.note, index = i,
            hull = r.hull, role = r.role,
            players = r.players, bots = r.bots, live = r.live,
            choice = ci, choices = cn,
            pick = (r.go or r.act) ~= nil,
            mark = r.mark and r.mark() or false,
        }
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
            out.rows = {}
            for i, r in ipairs(rows_of(nd2)) do
                local d = r.detail
                if type(d) == "function" then d = d() end
                local ci, cn
                if r.choice then ci, cn = r.choice() end
                out.rows[i] = {label = r.label, detail = d, note = r.note,
                               index = i, hull = r.hull, role = r.role,
                               players = r.players, bots = r.bots,
                               live = r.live, choice = ci, choices = cn,
                               pick = (r.go or r.act) ~= nil,
                               mark = r.mark and r.mark() or false}
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

    local id = M.stack[#M.stack]
    -- Built once. A node's rows may be a function, and asking it three times
    -- to move a cursor one row is three lists allocated to answer one
    -- keystroke.
    local nd = node()
    local rows = rows_of(nd)
    local n = #rows

    -- A grid reads its own arrows. Everywhere else right is enter, which is
    -- what a one-column list wants and exactly wrong on a page laid out in
    -- four: pressing right to look at the hull beside this one flew it
    -- instead, and down, which should have gone to the row below, went one
    -- ship to the right. Enter is still the only thing that picks.
    if nd.grid and #M.stack > 1 and n > 0 then
        local cols = math.max(1, math.min(M.cols, n))
        local i = row_index(rows)
        if keys.back then return back() end
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

    if keys.back or keys.left then return back() end

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
function M.click_rail(index)
    if not M.open then return nil, false end
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
