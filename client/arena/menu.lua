-- The menu, which is a tree you open while you are already flying.
--
-- There is no start screen. A player arrives in the arena with a hull, a call
-- sign and live controls, and everything that used to be a decision made
-- before playing is a decision made during it. That is the whole design: the
-- fastest way into a game is not to put anything in front of it.
--
-- One list on screen at a time, a breadcrumb above it, and a stack behind it.
-- Down and up move, right or enter descends or acts, left or escape goes
-- back, and escape at the root closes. Five inputs, which is what a d-pad
-- has, what a phone can draw as four arrows and a button, and what a keyboard
-- already sends -- so the same tree works on all three without a second
-- layout. A two-pane menu reads better on a desktop and falls apart at 390
-- points wide.
--
-- Selection only, still: this decides nothing and steps nothing. It reports
-- an action and arena.script carries it out.

local callsign = require("arena.callsign")

local M = {}

M.open = false
M.class = 0             -- the hull you are flying, kept in step with the sim
M.pending = nil         -- the one a row just asked for
M.stack = {"root"}
M.sel = {}              -- selected row, per node, so a level remembers
M.note = nil            -- set by the arena when a connection fails

-- Who you are, and where the games are.
--
-- Nothing here is typed. The name is generated -- a player is flying
-- immediately, a phone never has to raise a keyboard, and a console will hand
-- us the platform's own name when we get there. The directory is
-- configuration rather than input: ZONES asks it what is running and the
-- player picks from the list.
--
-- There is deliberately no address field. A game whose front door is a text
-- box asking for a websocket URL is a game with a text box in it, and the
-- machinery under one -- an invisible DOM input over the canvas, focus
-- handed back and forth, enter delivered to whichever of the two had the
-- caret -- was the single largest source of bugs in this client.
M.name = "pilot"
M.directory = "ws://127.0.0.1:9000"

-- Settings. Kept here because this is what saves them, and read by whoever
-- owns the thing they change.
M.volume = 3            -- index into VOLUMES
M.cap = 1               -- index into CAPS
M.can_cap = false       -- whether this engine can be asked to cap frames

local VOLUMES = {{0, "off"}, {0.3, "quiet"}, {0.6, "half"}, {1.0, "full"}}
local CAPS = {{0, "display"}, {60, "60 a second"}, {30, "30 a second"}}

local SAVE = sys.get_save_file("vectorwake", "pilot")

function M.save_identity()
    pcall(sys.save, SAVE, {
        name = M.name, class = M.class, volume = M.volume, cap = M.cap,
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
        if type(d.cap) == "number" then M.cap = d.cap end
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
    -- A browser drives the frame loop from requestAnimationFrame, so on a
    -- 120 Hz laptop the game renders twice as often as on a 60 Hz one and
    -- costs twice the battery for it. The simulation is 100 Hz either way,
    -- so this is a picture setting, not a game one -- which is exactly why
    -- it is the player's to make rather than ours.
    M.can_cap = pcall(sys.set_update_frequency, CAPS[M.cap][1])
end

function M.reroll()
    M.name = callsign.generate()
    M.save_identity()
end

-- Configuration, for a build that is pointed somewhere: a test naming its
-- clients, or an operator running their own directory.
function M.defaults(name, directory)
    if name and name ~= "" then M.name = name end
    if directory and directory ~= "" then M.directory = directory end
end

-- --- the tree ---------------------------------------------------------------
--
-- A row is a label, an optional detail that may be a function of the moment,
-- and one of: `go` to descend, or `act` for the arena to carry out. A row with
-- neither is a line of text, which is what `about` is made of.

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

local NODES = {
    root = {title = "vectorwake", rows = {
        {label = "ship", detail = function() return HULLS[M.class + 1][1] end,
         go = "ship"},
        {label = "play", detail = function() return M.where or "practice" end,
         go = "play"},
        {label = "pilot", detail = function() return M.name end, go = "pilot"},
        {label = "settings", go = "settings"},
        {label = "help", go = "help"},
        {label = "about", go = "about"},
    }},

    ship = {title = "ship", rows = hull_rows()},

    play = {title = "play", rows = {
        {label = "practice", detail = "eight AI pilots and four flags",
         act = "practice"},
        {label = "duel", detail = "first to five, one on one", act = "duel"},
        {label = "zones", detail = "find a game to join", act = "zones"},
    }},

    pilot = {title = "pilot", rows = {
        {label = "call sign", detail = function() return M.name end,
         act = "reroll"},
        {label = "", detail = "a name is drawn for you and kept between visits"},
    }},

    settings = {title = "settings", rows = {
        {label = "sound", detail = function() return VOLUMES[M.volume][2] end,
         act = "volume"},
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
        {label = "fly", detail = "left thumb: point where you want to go"},
        {label = "back up", detail = "point behind you and it reverses,"},
        {label = "", detail = "holding your aim instead of turning around"},
        {label = "come about", detail = "point at the ringed enemy instead and"},
        {label = "", detail = "the ship turns to face them, near or behind"},
        {label = "fire", detail = "right pads: guns, then bombs"},
        {label = "charges", detail = "tap a charge pad to spend it"},
        {label = "", detail = ""},
        {label = "", detail = "on a keyboard"},
        {label = "fly", detail = "arrow keys, or WASD"},
        {label = "guns", detail = "space, or Z"},
        {label = "bombs", detail = "shift, or X"},
        {label = "use", detail = "C, or ctrl"},
        {label = "swap", detail = "V, or tab"},
        {label = "scores", detail = "I, or the info button"},
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

    about = {title = "about", rows = {
        {label = "", detail = "a top-down space game about frictionless flight"},
        {label = "", detail = "energy is your health and your ammunition at once"},
        {label = "", detail = ""},
        {label = "", detail = "the bar over a ship is its energy, which is its"},
        {label = "", detail = "health and its ammunition at once"},
        {label = "", detail = "the number under it is its bounty: what killing"},
        {label = "", detail = "it pays, and what dying costs you"},
        {label = "", detail = function()
            return "build " .. (sys.get_config("project.version") or "dev")
        end},
    }},
}

-- --- navigation -------------------------------------------------------------

local function node()
    return NODES[M.stack[#M.stack]]
end

local function row_index()
    local id = M.stack[#M.stack]
    local n = #node().rows
    local i = M.sel[id] or 1
    if i > n then i = n elseif i < 1 then i = 1 end
    M.sel[id] = i
    return i
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
-- version of this kept the stack, and pressing escape then down then enter --
-- which had meant "duel" a moment earlier -- silently changed hull instead.
function M.close()
    M.open = false
    M.stack = {"root"}
    -- The row as well as the level. Resetting only the stack left the root
    -- sitting on whatever was last chosen there, so escape-then-enter went
    -- wherever you went last time rather than into the first row -- the same
    -- class of surprise, one level up.
    M.sel = {}
end

local function back()
    if #M.stack > 1 then
        table.remove(M.stack)
        return true
    end
    M.close()
    return true
end

-- What the drawing code needs, and nothing about how it is drawn. `detail` is
-- resolved here so ui.lua never calls back into this file mid-frame.
function M.view()
    local nd = node()
    local sel = row_index()
    local out = {title = nd.title, depth = #M.stack, sel = sel,
                 note = M.note, rows = {}}
    for i, r in ipairs(nd.rows) do
        local d = r.detail
        if type(d) == "function" then d = d() end
        out.rows[i] = {
            label = r.label, detail = d, index = i, hull = r.hull,
            pick = (r.go or r.act) ~= nil,
            mark = r.mark and r.mark() or false,
        }
    end
    return out
end

-- Activate the selected row. Returns an action for the arena, or nil.
local function activate()
    local nd = node()
    local r = nd.rows[row_index()]
    if not r then return nil end
    if r.go then
        M.stack[#M.stack + 1] = r.go
        return nil
    end
    if not r.act then return nil end

    -- The ones this file can settle itself.
    if r.act == "ship" then
        -- A request, not a decision. The hull you are flying is whatever the
        -- simulation says it is -- in a zone that is the server's answer, and
        -- it can refuse -- so this reports what was asked for and lets the
        -- arena find out. `M.class` follows the ship, never leads it.
        M.pending = r.value
        return "ship"
    elseif r.act == "reroll" then
        M.reroll()
        return nil
    elseif r.act == "volume" then
        M.volume = M.volume % #VOLUMES + 1
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
-- by the arena script -- a tap can go down and up inside one frame and never
-- appear in the key state that flight reads.
--
-- Returns an action name or nil, and whether anything moved, so the caller
-- can make a noise about it.
function M.step(keys)
    if not M.open then return nil, false end

    if keys.back or keys.left then return nil, back() end

    local id = M.stack[#M.stack]
    local n = #node().rows
    if keys.up then
        M.sel[id] = (row_index() - 2) % n + 1
        return nil, true
    end
    if keys.down then
        M.sel[id] = row_index() % n + 1
        return nil, true
    end
    if keys.go or keys.right then return activate(), true end
    return nil, false
end

-- A pointer landed on a row the interface published.
function M.click(index)
    if not M.open then return nil, false end
    local id = M.stack[#M.stack]
    if index == -1 then return nil, back() end
    M.sel[id] = index
    return activate(), true
end

return M
