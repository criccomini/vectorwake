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
-- The words for what a kit slot is, which the corner stack already uses while
-- a pilot flies. One vocabulary, so nothing is learned twice.
local pal = require("arena.palette")
-- For the protocol number the about page prints. Reading it from the module
-- that speaks it is what keeps the page honest when the wire changes.
local net = require("arena.net")
local callsign = require("arena.callsign")
local directory = require("arena.directory")
local install = require("arena.install")
local sfx = require("arena.sfx")
local binds = require("arena.binds")
local keyset = require("arena.keys")

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
-- Whether a thumb is driving this rather than a keyboard, set by the arena
-- each frame. The controls page is the one page whose rows depend on it: on
-- glass there is no board to draw and no key column to fill in, so the same
-- list comes out as gestures instead.
M.touching = false

-- Which control is waiting for a key, and nothing while none is. It is the
-- whole of the binding mode: the page draws the board dark around it and the
-- arena hands it the next press instead of walking the cursor with it.
M.arming = nil
-- One line under the controls page: what it is waiting for, or what it just
-- did. Cleared by anything that moves the cursor, so it is never a caption on
-- a row that has since changed.
M.foot = nil

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
-- The page the last tick was on, so the two that fetch their own contents can
-- ask on the way in rather than on every frame they are up.
local was_at = nil
-- Seconds until the friends page may ask again, counted down off the tick's
-- own delta rather than read off a clock. Presence is the one thing in this
-- menu that changes without the player doing anything, so it is the one page
-- that re-asks while it is open. Five seconds is a friend appearing in a game
-- about as fast as somebody would believe, and one request per open page is a
-- load the meta-layer will not notice.
local friends_due = 0
local FRIENDS_EVERY = 5
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
-- The first successful zone join offers the keyboard help once. This belongs
-- with the saved pilot rather than the current connection, so a reload cannot
-- bring the offer back after it has been dismissed.
M.help_prompt_seen = false
-- Which of the two flying controls a thumb gets: false is the stick that
-- points where the nose should go, true is the d-pad that pushes. The arena
-- reads it and arena/touch.lua acts on it; nothing here draws with it. See
-- the settings page below for why it is only offered on glass.
M.dpad = false

-- Whether the ship page's answer is currently "no hull". In a game that is
-- what the connection says you are; on the home screen it is what you have
-- asked to arrive as. One question, two places it can be answered from.
function M.spectating()
    if M.home then return M.spectate end
    return M.watching
end

-- Whether the room is between matches. A zone that plays no matches has no
-- between, and a zone that does spends twenty five seconds of every three
-- minutes here: it is the window the hangar opens in.
function M.between()
    local m = net.match
    return m ~= nil and not m.playing
end

local VOLUMES = {{0, "off"}, {0.3, "quiet"}, {0.6, "half"}, {1.0, "full"}}
-- The soundtrack is its own mixer group and its own row, because wanting the
-- game loud and the music off is the commonest thing anybody wants out of a
-- game's audio and one number cannot say it. Its ceiling is below the
-- effects' on purpose: a soundtrack you have to shout over is one you turn
-- off, and then all this was for nothing.
local MUSICS = {{0, "off"}, {0.2, "quiet"}, {0.45, "half"}, {0.75, "full"}}
local CAPS = {{0, "display"}, {60, "60 a second"}, {30, "30 a second"}}

-- The hulls, up here with the other tables a saved setting indexes rather than
-- down with the pages that draw them. A save is read before any page exists,
-- and a guard written against a table declared below it is not a guard: Lua
-- resolves the name at compile time, so it would read a nil global and admit
-- everything.
-- The roster, as a name, a silhouette and what that silhouette costs you.
--
-- These used to describe stats: the lightest bar, the biggest bomb, no bomb
-- rack. None of it was true of the simulation and all of it is false now on
-- purpose. Every hull flies alike, climbs alike and holds alike; what differs
-- is the shape it puts between a bullet and the pilot, and since weapons test
-- the oriented rectangle rather than a box drawn round it, that shape is a
-- real number in a real fight. So the sentence describes the shape.
local HULLS = {
    {"Apex", "dart", "a long nose and narrow flanks, awkward through a gap"},
    {"Wedge", "delta", "broad across the beam, hard to miss from the front"},
    {"Chord", "bow", "the widest hull and the shortest, all of it beam"},
    {"Anvil", "slab", "blunt and even, no face much thinner than another"},
    {"Cipher", "knife", "six pixels from the side, twenty-two down the nose"},
    {"Facet", "wedge", "the smallest target on the roster from any angle"},
    {"Lattice", "cross", "near square, so it turns anywhere it fits"},
}

local SAVE = sys.get_save_file("vectorwake", "pilot")

-- A saved number is only worth what the table it indexes says it is worth.
--
-- Everything here came out of a file this build did not necessarily write.
-- Both of these lists have changed size before -- the hulls were eight and are
-- seven, the frame caps offered a rate this build no longer has -- and a stale
-- index survived into a table that had shrunk under it. The read that followed
-- was `TABLE[i][1]` on a nil, which is not something the pcall around the
-- call could catch: Lua evaluates an argument before the call it belongs to,
-- so the raise happened in the caller. That is a client that fails in
-- `load_identity` on every boot, before it can reach the row that would fix
-- the value, and the save it keeps failing on is never rewritten.
local function saved_index(v, list, fallback)
    if type(v) ~= "number" then return fallback end
    v = math.floor(v)
    if v < 1 or v > #list then return fallback end
    return v
end

function M.save_identity()
    pcall(sys.save, SAVE, {
        name = M.name, class = M.class, volume = M.volume, music = M.music,
        cap = M.cap, zone = M.zone, spectate = M.spectate,
        help_prompt_seen = M.help_prompt_seen, dpad = M.dpad,
        -- Only the keys that have been moved, so a stock keyboard writes
        -- nothing here at all and a control this build stops carrying does
        -- not leave a line behind it. See arena/binds.lua.
        keys = binds.save_table(),
    })
end

-- A call sign has to outlive the tab. Ratings are keyed by who you are, and a
-- player who is somebody new on every reload has no record to build.
function M.load_identity()
    callsign.seed(os.time() + math.floor(os.clock() * 100000))
    M.help_prompt_seen = false
    local ok, d = pcall(sys.load, SAVE)
    if ok and type(d) == "table" and type(d.name) == "string" and d.name ~= "" then
        M.name = d.name
        -- The hull is a zero-based index, so it is checked one off from the
        -- rest. It used to be taken modulo eight against seven hulls, which
        -- let a class of 7 through to be read as HULLS[8].
        M.class = saved_index(type(d.class) == "number" and d.class + 1 or nil,
                              HULLS, M.class + 1) - 1
        M.volume = saved_index(d.volume, VOLUMES, M.volume)
        M.music = saved_index(d.music, MUSICS, M.music)
        M.cap = saved_index(d.cap, CAPS, M.cap)
        -- The game you were in last, so coming back puts the cursor on it and
        -- a returning player is one press from flying.
        if type(d.zone) == "string" then M.zone = d.zone end
        -- What you last chose to arrive as. Saved beside the hull because it
        -- is an answer to the same question the hull answers.
        M.spectate = d.spectate == true
        M.help_prompt_seen = d.help_prompt_seen == true
        -- Compared against true rather than read, so a save carrying anything
        -- else under this name lands on the stick rather than on a value the
        -- touch layer would try to steer with.
        M.dpad = d.dpad == true
        -- Whatever survives being read against this build's key list. A
        -- missing table is a stock keyboard, which is what `load` does with
        -- nothing.
        binds.load(d.keys)
    else
        M.name = callsign.generate()
        M.save_identity()
    end
    M.apply_settings()
end

function M.needs_help_prompt()
    return not M.help_prompt_seen
end

function M.dismiss_help_prompt()
    if M.help_prompt_seen then return end
    M.help_prompt_seen = true
    M.save_identity()
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

-- The kit space's shape, off the core.
--
-- Through `_G.sim` at the moment of asking rather than captured at load,
-- because this module is required before the extension has published its
-- table in some harnesses and the real client always has it. The fallbacks
-- are the compiled numbers and `constant_drift_test` holds them to the C, so
-- a core that moved one of them fails there rather than on a screen.
local function simn(key, fallback)
    local s = _G.sim
    return (s and tonumber(s[key])) or fallback
end

-- The kit space, as a list a person can walk.
--
-- The core's space is flat and every slot in it costs one: five stats, a rung
-- on each trigger, an add-on per trigger per kind, then the charges. This is
-- that space in the order a pilot thinks about it, with the names the corner
-- stack already uses so nothing has to be learned twice.
--
-- Only the slots the hull will take and the account owns appear. A row for
-- something you cannot put on this ship is a row that does nothing when
-- pressed, and a page of twenty-three of those is not a page.
-- Declared here and built below: the kit page's first row is the ship it is
-- spending on, and the roster it walks through is defined with the other
-- pages.
local hull_rows

local function kit_slots()
    local out = {}
    local up = simn("UP_COUNT", 5)
    local trig = simn("TRIG_COUNT", 2)
    local mods = simn("MOD_COUNT", 6)
    -- `short` and `tint` travel with every slot, because the page draws each
    -- group in its own shape: a stat is a row of steps behind a three-letter
    -- mark, an add-on is a chip, and a charge is a count. The interface picks
    -- the shape; this says what the thing is.
    for u = 0, up - 1 do
        local s = pal.UPGRADES[u + 1]
        out[#out + 1] = {slot = u, label = s and s.name or ("stat " .. u),
                         short = s and s.short or "?", tint = s and s.col,
                         group = "flight"}
    end
    -- A trigger's ladder is a ladder, not a switch. Both of these used to be
    -- chips wearing the word "rung", which is one word for two different
    -- weapons and says nothing about which rung you are on: a pilot could not
    -- tell L1 from L3 or find a way to climb. They are drawn as steps now,
    -- beside the stats, and the count beside the steps is the level.
    for t = 0, trig - 1 do
        out[#out + 1] = {slot = simn("SLOT_LEVEL0", up) + t,
                         label = (t == 0 and "gun" or "bomb") .. " level",
                         short = t == 0 and "gun" or "bmb",
                         tint = t == 0 and pal.CHARGE_COL or pal.BOMB,
                         trigger = t, group = "levels"}
    end
    for t = 0, trig - 1 do
        for m = 0, mods - 1 do
            local mod = pal.MODS[m + 1]
            out[#out + 1] = {
                slot = simn("SLOT_MOD0", up + trig) + t * mods + m,
                label = (t == 0 and "gun " or "bomb ") ..
                        (mod and mod.name or ("add-on " .. m)),
                short = mod and mod.short or ("add-on " .. m),
                note = mod and mod.long or nil,
                trigger = t, group = "weapons",
            }
        end
    end
    for k = 0, simn("MAX_CHARGES", 4) - 1 do
        local c = pal.CHARGES[k + 1]
        out[#out + 1] = {slot = simn("SLOT_CHARGE0", up + trig + trig * mods) + k,
                         label = c and c.name or ("charge " .. k),
                         short = c and c.short or "?",
                         -- The color they go off in, which the page used to
                         -- hardcode where it drew them and now travels with
                         -- the slot like every other row's does.
                         tint = pal.CHARGE_COL, group = "charges"}
    end
    return out
end

-- What this pilot may put in each slot: the arena's own row and the account's
-- entitlements together, smaller wins.
--
-- Two ceilings, where there were three. The hull used to carry one, and it is
-- the one that went: a roster that said which add-ons a hull would hold was a
-- roster that could refuse an upgrade somebody had bought, and nothing could
-- be sold that only one hull had. So a hull is a shape now and the tech
-- tree is the arena's. See docs/design/ships.md.
--
-- The arena checks the same thing when a kit arrives, against the entitlements
-- the token carries rather than against this copy. That is the check that
-- matters; this one is so the page never offers a step it would be refused
-- for taking.
local function kit_ceiling()
    local core = _G.sim
    local hull = core and core.kit_ceilings and core.kit_ceilings() or nil
    local own = account.entitlements or {}
    -- The baseline where the account has said nothing, which is a deployment
    -- with no meta-layer and a session that has not answered yet. Not "no
    -- limit": that offered a mine to a pilot who cannot slot one, and the
    -- arena, which reads the same baseline, refused it.
    local base = (core and core.base_entitlements and core.base_entitlements())
        or {}
    local out = {}
    for i = 1, simn("SLOT_COUNT", 25) do
        local h = hull and hull[i] or 0
        local o = own[i] or base[i] or 255
        out[i] = math.min(h, o)
    end
    return out
end

-- The kit being edited, which is this pilot's own for the hull they are on.
-- Held here rather than read back off the ship every frame: a hull the pilot
-- is not flying has no ship to read, and a kit is a thing you are composing
-- until you leave the page.
M.kit = nil
M.kit_class = nil

-- Which cell of the roster the carousel is showing. An index rather than a
-- hull, because the last cell is not one: sitting out is the ninth answer to
-- "what are you flying" and rides the carousel with the other eight.
--
-- Nil until somebody turns it, and then it is what the page reads. Derived
-- before that from what the pilot is actually in, so the page opens on their
-- own ship rather than on the first of the list.
M.hull_at = nil

function M.hull_index()
    local n = #hull_rows()
    local at = M.hull_at or (M.spectating() and n) or ((M.class or 0) + 1)
    return math.max(1, math.min(math.max(n, 1), at))
end

-- Start editing the kit for a hull, from the account where it has one and
-- from what the ship is already wearing where it does not.
function M.open_kit(class)
    local saved = account.kits and account.kits[HULLS[class + 1][1]]
    local kit = {}
    for i = 1, simn("SLOT_COUNT", 25) do
        kit[i] = tonumber(saved and saved[i]) or 0
    end
    -- Nothing saved: what the arena would deal, computed by the same core the
    -- arena deals with, so the hangar and the ship agree before anybody has
    -- joined anything.
    --
    -- An empty kit is the one answer that would be wrong. Nobody flies bare,
    -- so a hangar that opened on nothing would be showing a ship that does
    -- not exist and inviting a player to build one from scratch every time.
    local core = _G.sim
    if M.kit_spent(kit) == 0 and core and core.starter_kit then
        kit = core.starter_kit(kit_ceiling())
    end
    M.kit, M.kit_class = kit, class
end

function M.kit_spent(kit)
    local n = 0
    for _, v in ipairs(kit or M.kit or {}) do n = n + v end
    return n
end

-- One slot, up or down by one, inside every ceiling and the budget.
--
-- Refused rather than clamped where it does not fit, so the page never shows
-- a kit the arena would not take: what a player sees here is what they will
-- fly.
function M.kit_step(slot, by)
    if not M.kit then return false end
    local ceiling = kit_ceiling()
    local at = M.kit[slot + 1] or 0
    local want = at + by
    if want < 0 or want > (ceiling[slot + 1] or 0) then return false end
    if by > 0 and M.kit_spent() >= simn("KIT_BUDGET", 30) then return false end
    M.kit[slot + 1] = want
    return true
end

-- A slot set straight to a step, which is what pressing the fourth pip of a
-- ladder means. The row used to be one target and a press added one, so
-- reaching four from nothing was four clicks on a thing that looks like a
-- slider.
--
-- As far as it will go rather than refused: asking for four with two points
-- left and one held spends both and stops at three. A press on a ladder is a
-- pilot saying how much of this they want, and the honest answer to "more
-- than you can afford" is what they can.
function M.kit_set(slot, want)
    if not M.kit then return false end
    local ceiling = kit_ceiling()
    local at = M.kit[slot + 1] or 0
    want = math.max(0, math.min(want, ceiling[slot + 1] or 0))
    if want > at then
        local left = simn("KIT_BUDGET", 30) - M.kit_spent()
        want = math.min(want, at + math.max(0, left))
    end
    if want == at then return false end
    M.kit[slot + 1] = want
    return true
end

-- The kit for a hull, as rows. `class` is the hull being asked about, which
-- is the one being edited on the kit page and the one under the cursor while
-- the roster has it: standing on a hull in the hangar shows what it will fly,
-- which is the question the roster is being asked.
--
-- Switching to it is not destructive. A point spent saves the kit as it is
-- spent, so the kit a hull comes back with is the kit it was left with, and
-- moving the cursor along the roster loads each in turn rather than editing
-- any of them.
local function kit_rows(class)
    class = class or M.kit_class or M.class
    if not M.kit or M.kit_class ~= class then M.open_kit(class) end
    local ceiling = kit_ceiling()
    -- What the arena alone would allow, which is a longer ladder than the
    -- account's wherever the shelf still holds a step. Drawn behind what you
    -- own, so a page says "there is more of this and it is not yours" without
    -- a word about it.
    local core = _G.sim
    local arena_ceiling = (core and core.kit_ceilings
                           and core.kit_ceilings()) or ceiling
    local budget = simn("KIT_BUDGET", 30)
    -- At the head, not the foot. It is the number every row below is
    -- spending, and a list long enough to scroll would push it off the
    -- bottom of the one page where it matters most.
    -- Drawn as one bar rather than as the ladder every other row uses: thirty
    -- steps at the width a step is drawn runs the length of the row and lands
    -- on top of the word "budget".
    -- The ship, first, because it is what the rest of the page is spending
    -- on. It is a row like any other so that the arrows reach it: left and
    -- right turn the carousel, enter asks for the hull under it, and up off
    -- it goes back to the tab row.
    --
    -- This page and the roster used to be two levels of the stack, and the
    -- kit drawn beside the roster was a preview: nothing in it was the cursor
    -- and nothing in it took a press. With the roster down to one ship on a
    -- carousel there is no level above this one left to stand on, so the
    -- preview became a page that looked exactly like the editor and answered
    -- nothing. See docs/design/ships.md.
    local hulls = hull_rows()
    local at = M.hull_index()
    local cell = hulls[at]
    local rows = {{
        label = cell and cell.label or "ship", verbatim = true, ship = true,
        act = "hull", value = cell and cell.value or nil,
        choice = function() return at, #hulls end,
        mark = cell and cell.mark or nil,
    }, {
        label = "budget", verbatim = true, bar = true,
        detail = M.kit_spent() .. " of " .. budget,
        choice = function() return M.kit_spent(), budget end,
    }}
    for _, s in ipairs(kit_slots()) do
        local max = ceiling[s.slot + 1] or 0
        -- On the page if the arena has the slot at all, not if the account
        -- owns a rung of it. The two used to be the same test, so a slot you
        -- owned none of had no row: add-ons arrived granted, so only barrels
        -- and the mine were ever missing, and nobody could see that the one
        -- trait the whole slot space was flattened to make sellable existed.
        -- Nothing is granted now, so that test would have emptied the page.
        if (arena_ceiling[s.slot + 1] or 0) > 0 then
            local held = M.kit[s.slot + 1] or 0
            rows[#rows + 1] = {
                label = s.label,
                detail = tostring(held),
                -- The range as steps with the one it is on lit, which is what
                -- every other setting in this menu draws and says "four of
                -- six" in the shape of the thing rather than in a number that
                -- has to be compared against the number on the row above.
                choice = function() return held, max end,
                act = "kit_step", value = s.slot,
                -- What the page needs to draw this slot as the thing it is
                -- rather than as another row: which group it belongs to, its
                -- own short mark, its color, and which trigger it hangs off.
                group = s.group, short = s.short, tint_col = s.tint,
                trigger = s.trigger, note = s.note,
                -- What the account owns here, against what the arena would
                -- take. The difference is the part of the ladder that is
                -- still for sale, and the page draws it as a step that is
                -- there and not yours.
                owned = max, arena_max = arena_ceiling[s.slot + 1] or max,
            }
        end
    end
    return rows
end

-- The shelf: every slot with a step left on it, priced.
--
-- Built from what the account owns and what the core's space allows, which is
-- the same pair the hangar reads. What a step costs is the meta-layer's
-- answer and arrives with the shelf; until it has answered there is nothing
-- to draw and the page says so rather than inventing a price.
local function upgrade_rows()
    local rows = {}
    -- Which part of the kit space a slot belongs to, so the shelf reads as
    -- three short lists rather than as one long one. The meta-layer sends the
    -- slot; what a slot means is the core's own arithmetic and is already
    -- here.
    local up = simn("UP_COUNT", 5)
    local trig = simn("TRIG_COUNT", 2)
    local mods = simn("MOD_COUNT", 6)
    local level0 = simn("SLOT_LEVEL0", up)
    local charge0 = simn("SLOT_CHARGE0", up + trig + trig * mods)
    local mod0 = simn("SLOT_MOD0", up + trig)
    local function kind_of(slot)
        if not slot then return nil end
        if slot < level0 then return "stats" end
        if slot >= charge0 then return "charges" end
        return "triggers"
    end
    -- What the card is a picture of. The slot number is the meta-layer's, and
    -- what a slot means is arithmetic the core owns and this file already
    -- does, so the row carries the answer and the drawing carries none of the
    -- arithmetic.
    local function icon_of(slot)
        if not slot then return nil end
        if slot < level0 then return {kind = "stat", i = slot} end
        if slot >= charge0 then return {kind = "charge", i = slot - charge0} end
        if slot < mod0 then return {kind = "level", trigger = slot - level0} end
        local at = slot - mod0
        return {kind = "mod", trigger = math.floor(at / mods), mod = at % mods}
    end
    local was = nil
    for _, item in ipairs(account.shelf or {}) do
        local afford = (account.rivets or 0) >= (item.price or 0)
        local kind = kind_of(item.slot)
        local sect = (kind ~= was) and kind or nil
        was = kind
        rows[#rows + 1] = {
            sect = sect,
            label = item.label or ("slot " .. tostring(item.slot)),
            -- The number alone. The page draws the rivet mark in front of it,
            -- the way a price is written everywhere else in the world.
            detail = item.price or 0, price = item.price or 0,
            icon = icon_of(item.slot),
            note = item.note,
            -- Back a shade rather than hidden when the wallet is short: a
            -- page that shows only what you can afford is a page that never
            -- tells you what you are saving for. `full` is the shade and
            -- nothing else; the price stays on the row, which is the whole
            -- point of leaving it there.
            full = not afford,
            -- Pressable whatever the wallet says. It used to carry an action
            -- only when it was affordable, and a row with no action publishes
            -- no hit box, so a pilot with no rivets met a page where the mouse
            -- did nothing at all: no hover, no click, no reason given. The
            -- keyboard still walked it, which is how it survived a playtest.
            --
            -- The refusal is the meta-layer's and it already exists, so a press
            -- on something you cannot afford comes back saying so.
            act = "buy", value = item.slot,
        }
    end
    return rows
end

local function upgrades_empty()
    if account.shelf and #account.shelf > 0 then return nil end
    if account.base == "" then
        return {head = "nothing to upgrade here",
                line = "this deployment keeps no accounts"}
    end
    -- Asked and not yet answered. It used to say the shelf was empty, which
    -- is a sentence about the account: a new pilot owns almost nothing and
    -- was told they owned everything, because the request was still out.
    if not account.shelf then
        return {head = "asking for the shelf",
                line = "what is on sale is coming"}
    end
    return {head = "nothing left to buy",
            line = "you own every slot the roster has"}
end

-- The week. Read off the standings the meta-layer publishes, which is the
-- same list the public site draws.
-- How long somebody was in a room, as a person reads it.
local function spell_time(secs)
    secs = math.max(0, math.floor(tonumber(secs) or 0))
    if secs < 60 then return secs .. "s" end
    local mins = math.floor(secs / 60)
    if mins < 60 then return mins .. "m" end
    return math.floor(mins / 60) .. "h " .. (mins % 60) .. "m"
end

local function standings_rows()
    local rows = {}
    for i, p in ipairs(account.week or {}) do
        rows[#rows + 1] = {
            label = p.name or "?", named = true,
            -- Pressable, so the panel beside the table can say more about one
            -- pilot than a row has room for. A row with no action publishes no
            -- hit box, which is why this table did not answer a mouse at all.
            act = "inspect_pilot", value = i,
            -- A table rather than a sentence: the page draws these in their
            -- own columns, so the row carries the numbers and not a phrasing
            -- of them. `detail` is what a list would have shown and is what
            -- the preview still shows.
            detail = (p.kills or 0) .. "k",
            rank = i, kills = p.kills or 0, deaths = p.deaths or 0,
            run = p.run or 0, played = spell_time(p.seconds),
            -- Signed, because a week that cost you rating is the fact
            -- somebody is looking for and an unsigned 40 reads as a gain.
            rating = p.rating or 0,
            mark = function() return p.name == M.name end,
        }
        if i >= 20 then break end
    end
    return rows
end

local function standings_empty()
    if account.week and #account.week > 0 then return nil end
    if not account.week then
        return {head = "asking for the table", line = "the week is coming"}
    end
    return {head = "nobody has played this week yet",
            line = "the table resets on Monday"}
end

-- The friends page: three sections, from one reply.
--
-- Friends first, the ones in a game at the top of them, because "who is on"
-- is the question this page exists to answer. Then whoever has added you and
-- is waiting, which is the only inbox this game has and holds names and
-- nothing else. Then whoever is in the room with you, which is the whole of
-- how a name reaches this page: there is no directory of the fleet and no way
-- to search for anybody. See docs/design/friends.md.
-- One name a row, under a head that belongs to the row opening its run: the
-- list renderer draws a head wherever it finds a `sect` and dedupes nothing,
-- so a label on every row is that label over every row.
local function name_rows(rows, head, list, fill)
    for i, p in ipairs(list or {}) do
        local r = fill(p)
        r.label = p.name or "?"
        r.named = true
        r.value = p.account
        if i == 1 then r.sect = head end
        rows[#rows + 1] = r
    end
end

local function friend_rows()
    local rows = {}
    name_rows(rows, "friends", account.friends, function(f)
        local where = directory.at_instance(f.instance)
        local flying = f.zone ~= nil and f.zone ~= ""
        return {
            -- Where they are, or that they are not anywhere. A friend in an
            -- instance this client cannot see reads as in that game and is
            -- not joinable, which is the honest answer for an arena the
            -- directory has stopped listing.
            detail = flying and f.zone or "not on",
            live = where ~= nil,
            zone = flying and f.zone or nil,
            joinable = where ~= nil,
            -- A card rather than an action, because there are two things to
            -- do with a friend and one of them takes both edges away. Five
            -- inputs and no second button means a row has one press, so the
            -- press asks. See docs/design/friends.md.
            act = "friend_card",
        }
    end)
    -- The other three are a name and one press, so they are a table rather
    -- than three copies of the same loop. Order is what they are for: people
    -- to answer, then people to add, then presses already made.
    local plain = {
        {head = "waiting on you", list = account.asked,
         detail = "add back", act = "befriend"},
        {head = "in this game", list = account.here,
         detail = "add", act = "befriend"},
        -- Last, because nothing happens on it. It exists so that adding
        -- somebody has a visible consequence: without it a press took a name
        -- off the list above and put it nowhere.
        {head = "you added", list = account.waiting,
         detail = "waiting on them", act = "friend_card"},
    }
    for _, sec in ipairs(plain) do
        name_rows(rows, sec.head, sec.list, function()
            return {detail = sec.detail, act = sec.act}
        end)
    end
    return rows
end

local function friends_empty()
    -- Only where there is nothing at all. A card under a list that has rows in
    -- it is a page saying two things at once, and the second one is wrong.
    if #(account.friends or {}) + #(account.asked or {})
        + #(account.here or {}) + #(account.waiting or {}) > 0 then
        return nil
    end
    if account.base == "" then
        return {head = "no accounts here",
                line = "this deployment keeps none, so there is nobody to add"}
    end
    if not account.have_friends then
        return {head = "asking", line = "your friends are coming"}
    end
    return {head = "nobody yet",
            line = "fly with somebody and add them from this page"}
end

function hull_rows()
    local rows = {}
    for i, h in ipairs(HULLS) do
        rows[i] = {
            label = h[1], detail = h[3], act = "ship", value = i - 1,
            hull = i - 1, role = h[2],
            -- The one fact about a hull that is not a matter of taste, read
            -- off the core rather than repeated here so the two cannot drift.
            extent = function()
                local core = _G.sim
                if not (core and core.hull_extent) then return nil end
                local fore, aft, halfw = core.hull_extent(i - 1)
                if not fore then return nil end
                return {fore = fore, aft = aft, beam = halfw * 2}
            end,
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
-- What the play page says beside its list: the room a press would put you in.
--
-- Read off the same directory row the cursor is on, because "where would this
-- put me" is a question about the thing under the cursor and not about the
-- fleet in general.
local function deploying(sel)
    local r = directory.rows[sel]
    if not r then return nil end
    local out = {head = "deploying to", label = r.name or "",
                 note = r.detail or "", rows = {}}
    if r.live then
        out.sub = "the busiest room with a seat"
        out.rows[#out.rows + 1] = {"people", tostring(r.players or 0)}
        out.rows[#out.rows + 1] = {"bots holding seats", tostring(r.bots or 0)}
    else
        out.sub = "nobody is running it"
    end
    out.foot = "a room takes you the moment you press play, and the bots "
               .. "stand down as people arrive"
    return out
end

local function play_rows()
    local rows = {}
    for i, r in ipairs(directory.rows) do
        rows[i] = {
            -- The games under a heading of their own. This page is three
            -- different questions in a column: which game, who is on, and
            -- where the talking happens. Run together they read as one list
            -- where Discord is a zone you could join.
            sect = (i == 1) and "zones" or nil,
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
    -- The side you are on, where there is a room to be on one in. A side is
    -- a thing a room has, so the row appears with the room rather than
    -- standing on the front end saying nothing.
    if not M.home and #net.teams > 0 then
        rows[#rows + 1] = {label = "side", detail = function()
            return net.my_team_name()
        end, go = "teams"}
    end
    -- Who is on. A row here rather than a seventh tab, for the reason the
    -- Discord row below is a row: this is where somebody is already thinking
    -- about who to play with. A tab would put "who is on" beside "how loud is
    -- the music" in a row of six equals, and it is not one of six equals, it
    -- is the other way into a game. See docs/design/friends.md.
    if account.base ~= "" then
        rows[#rows + 1] = {label = "friends", go = "friends",
                           sect = "friends", detail = function()
            local on = 0
            for _, f in ipairs(account.friends or {}) do
                if f.zone ~= nil and f.zone ~= "" then on = on + 1 end
            end
            if on > 0 then return on .. " in a game" end
            local waiting = #(account.asked or {})
            if waiting > 0 then
                return waiting .. (waiting == 1 and " waiting on you"
                                                 or " waiting on you")
            end
            if #(account.friends or {}) == 0 then return "nobody yet" end
            return "none on"
        end}
    end
    -- Where the community is, and the only outbound link in the game. It sits
    -- here because this is where somebody is already thinking about who to
    -- play with, which is the argument `community.md` makes and the reason it
    -- is not a tab: the game carries no chat, and the panel about finding
    -- people should be honest about where the talking happens.
    -- Drawn as a button rather than as a row, with the mark on it. It is not
    -- a page of this menu and reading as one is what it did.
    rows[#rows + 1] = {label = "Talk on Discord",
                       sect = "community", button = "discord",
                       act = "discord", link = DISCORD}
    -- Nothing about leaving down here. The way out of a game is the tab row's
    -- own leave, which is on it whenever there is something to leave.
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
    -- The tab row, and the whole of the front end's shape.
    --
    -- Six of them between matches, where there is time to read: play, hangar,
    -- upgrades, standings, pilot, settings. Two in a match: settings and leave.
    -- Same row in the same place, wearing the same chrome; what differs is
    -- which tabs are on it, not how any of it looks or works, so a player
    -- learns one screen and meets it in both places.
    --
    -- Nothing you cannot act on right now is on that row while you are
    -- flying. A three minute match is short enough that a menu deep enough to
    -- browse a shelf in costs a real fraction of it, and nothing pauses: you
    -- can be shot while you read. See docs/design/match-game.md.
    --
    -- It stays a tab row rather than a bare leave button for one reason that
    -- does not show up on a desktop. On a phone this is the only route to
    -- sound, to fullscreen and to the controls reference, and a leave button
    -- alone would strand a player who needs to mute the game.
    root = {rows = function()
        if not M.home then
            local rows = {}
            -- Between matches the hull is not locked, and this is the one
            -- window a pilot has to change it without leaving the room. It is
            -- gone again the moment the next whistle goes, which is the rule
            -- rather than a hurry we invented: a kit is spent inside a hull
            -- and both are settled before a match, never during one.
            if M.between() then
                rows[#rows + 1] = {label = "ship", icon = "ship",
                    detail = function()
                        if M.spectating() then return "spectating" end
                        return HULLS[M.class + 1][1]
                    end, go = "hangar"}
            end
            -- The people you are flying with, which is where a friend is
            -- made. One press from the card at the end of a match, because the
            -- menu opens over it.
            if account.base ~= "" then
                rows[#rows + 1] = {label = "friends", icon = "pilot",
                                   go = "friends", detail = function()
                    local n = #(account.here or {})
                    if n > 0 then return n .. " to add" end
                    return "who is on"
                end}
            end
            rows[#rows + 1] = {label = "settings", icon = "settings",
                               go = "settings"}
            rows[#rows + 1] = {label = "leave", icon = "zones",
                               detail = "back to the games", act = "leave"}
            return rows
        end
        return {
            {label = "play", icon = "zones", detail = function()
                if M.zone ~= "" then return M.zone end
                return "choose a game"
            end, go = "play"},
            -- The hull and its kit are one choice made in one place: a kit is
            -- spent inside a hull's own ceilings, so choosing a ship and
            -- choosing what to put on it are the same act seen twice.
            {label = "ship", icon = "ship",
             detail = function()
                 if M.spectating() then return "spectating" end
                 return HULLS[M.class + 1][1]
             end,
             go = "hangar"},
            {label = "upgrades", icon = "upgrades",
             detail = function() return (account.rivets or 0) .. " rivets" end,
             go = "upgrades"},
            {label = "standings", icon = "standings", detail = "this week",
             go = "standings"},
            -- No pilot stop. The call sign is already written at the far end
            -- of this row, and a tab whose whole detail is that same name says
            -- it twice. Pressing the name is the way in; see `M.click_pilot`.
            -- Everything about the machine rather than about a match, in one
            -- column: audio, video, the bindings, and about. Help folded into
            -- it because the controls board and the rebinding screen were
            -- always the same list read two ways.
            {label = "settings", icon = "settings", go = "settings"},
        }
    end},

    -- A grid, not a list: the hulls are drawings laid out in rows and columns,
    -- so left and right are a column apart and up and down are a row apart.
    -- Nothing else in the tree is, which is why it is a flag on the node
    -- rather than a rule about pages.
    -- A function rather than a table: the page is eight cells on the home
    -- screen and nine with a game behind it, so it has to be asked each time
    -- rather than built once at load.
    -- One ship, and what thirty points buy on it. One row a slot, the count
    -- as steps, and left and right spend and unspend the way they set every
    -- other value in this menu.
    --
    -- No grid. The roster was one, eight hulls laid out as cells with the kit
    -- of whichever one the cursor stood on drawn beside them, and picking a
    -- cell opened a second page for the kit. The roster is a carousel at the
    -- head of this page now, so both levels are this one.
    hangar = {rows = kit_rows},

    play = {rows = play_rows, empty = zone_empty},

    -- Who is on, who is waiting on you, and who you are playing with. One
    -- page, reachable from the games at home and from the tab row in a match,
    -- because those are the two places the question comes up. See
    -- docs/design/friends.md.
    friends = {rows = friend_rows, empty = friends_empty},

    -- What rivets buy: slots, and looks. Never strength.
    --
    -- One row a slot with something left on the shelf, priced, with what the
    -- account already owns beside it. Everything in a kit trades against the
    -- same thirty points, so what is on sale here is *which* upgrades a pilot
    -- may slot rather than how many. See docs/design/match-game.md.
    --
    -- The prices are the meta-layer's and are not written down here: a client
    -- that knew them would be a second copy to keep in step, and the reply to
    -- a purchase says what the slot now holds and what is left in the wallet.
    -- No heading. It said what the wallet holds, which the corner of the tab
    -- row says on every page, and then explained what rivets are to somebody
    -- who has opened the page to spend them.
    upgrades = {rows = upgrade_rows, empty = upgrades_empty},

    -- The week: matches won, kills, and the best run, resetting Monday. The
    -- short ladder beside the rating, which answers "how good am I" on a
    -- career scale and moves slowly.
    standings = {rows = standings_rows, empty = standings_empty},

    teams = {rows = team_rows},

    -- Not a stop on the tab row: the call sign in the corner is the way here,
    -- because that is the one thing on screen already naming the pilot. So it
    -- is marked as reached from off the row, or the guard below that shuts a
    -- page the row has stopped carrying would put a pilot straight back out of
    -- it, one frame after the corner let them in.
    pilot = {off_rail = true, rows = function()
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
            -- Grouped, the way the mocks group a list of settings: a small
            -- label and a ticked rule over each run of rows. What a group
            -- says is what the rows under it are about, which is the one
            -- thing a page of eight settings cannot say in its title.
            {label = "sound", sect = "audio",
             detail = function() return VOLUMES[M.volume][2] end,
             choice = function() return M.volume - 1, #VOLUMES - 1 end,
             act = "volume"},
            {label = "music", detail = function() return MUSICS[M.music][2] end,
             choice = function() return M.music - 1, #MUSICS - 1 end,
             act = "music"},
            {label = "frames", sect = "video", detail = function()
                if not M.can_cap then return "as the display asks" end
                return CAPS[M.cap][2]
            end, choice = function()
                if not M.can_cap then return nil end
                return M.cap, #CAPS
            end, act = "cap"},
            {label = "fullscreen", detail = "fill the screen",
             act = "fullscreen"},
        }
        -- Only where there are thumbs. A keyboard has a key for each of
        -- these and no question to answer.
        --
        -- One box, because it is one question, and a detail that names the
        -- control rather than saying "on": the two are alternatives and
        -- neither is the absence of the other.
        if M.touching then
            rows[#rows + 1] = {
                label = "steering",
                detail = function()
                    if M.dpad then return "a pad to push" end
                    return "a stick to point"
                end,
                choice = function() return M.dpad and 1 or 0, 1 end,
                act = "steering"}
        end
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
        -- The two pages that used to be tabs of their own. Both are about the
        -- machine rather than about a match, which is what this page is for:
        -- the controls board is where the keys are set, and `about` is three
        -- lines that never deserved a destination.
        rows[#rows + 1] = {label = "controls", sect = "the machine",
                           detail = "keys and pads", go = "controls"}
        rows[#rows + 1] = {label = "about", detail = "this build",
                           go = "about"}
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
    -- On a keyboard the page draws the keyboard, and every control on it is a
    -- chip under the picture carrying the key it is on. The chips are rows
    -- like any other page's, so the cursor, the pointer and the hit boxes are
    -- the ones every list here already has; what is different is that they are
    -- laid out three across, which is what `grid` and `cols` say.
    --
    -- The full list down one column would scroll, and a list that scrolls under
    -- a picture stops being the same page as the picture: you would be moving
    -- the answers past a diagram that stayed still.
    controls = {board = true, chips = true, grid = true, cols = 3,
                rows = function()
        local rows = {}
        for i, c in ipairs(binds.rows()) do
            if M.touching then
                -- No board and no key column on glass, so the page falls back
                -- to what a thumb does. A control with no `pad` cannot be
                -- worked by one at all and is left out rather than named.
                if c.pad then
                    rows[#rows + 1] = {label = c.pad_name or c.name,
                                       detail = c.pad}
                end
            else
                rows[i] = {label = c.name, detail = c.show, cat = c.cat,
                           control = c.id, keys = c.keys, fixed = c.fixed,
                           arming = M.arming == c.id,
                           act = "bind", pick = true}
            end
        end
        if not M.touching then
            -- Last, and after every control, because it is about all of them.
            rows[#rows + 1] = {label = "defaults", act = "defaults",
                               pick = true, reset = true}
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
            {label = "privacy", detail = "vectorwake.net/privacy",
             verbatim = true, act = "privacy"},
            {label = "terms", detail = "vectorwake.net/terms",
             verbatim = true, act = "terms"},
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

-- The page the stack is standing on, or the tab row when it names one that
-- does not exist here.
--
-- The fallback is load-bearing rather than defensive. The tab row is a
-- different row in a match than it is at the front end, so a stack left
-- pointing at the hangar when a match starts names a page that is no longer
-- reachable, and every caller of this was written assuming a page.
local function node()
    return NODES[M.stack[#M.stack]] or NODES.root
end

local function rows_of(nd)
    local r = nd.rows
    if type(r) == "function" then return r() end
    return r
end

-- Which page's rows are on screen. One level in that is the page you are
-- inside; at the root it is whichever tab the cursor is resting on, because
-- the stage there is a preview of what that tab holds.
function M.showing()
    if #M.stack > 1 then return M.at() end
    local top = rows_of(NODES.root)
    local r = top[M.sel.root or 1]
    return (r and r.go) or "root"
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
        extent = type(r.extent) == "function" and r.extent() or r.extent,
        players = r.players, bots = r.bots, live = r.live,
        choice = ci, choices = cn, bar = r.bar, ship = r.ship,
        -- What the hangar's page needs to draw a slot as the thing it is:
        -- its group, its short mark, its color, the trigger it hangs off, and
        -- how far the arena's own ladder runs past what the account owns.
        -- The label a group of rows sits under, on the first row of it.
        sect = r.sect,
        group = r.group, short = r.short, tint_col = r.tint_col,
        -- The week's own columns.
        rank = r.rank, kills = r.kills, deaths = r.deaths, run = r.run,
        played = r.played, rating = r.rating,
        -- What a shelf card is a picture of, and what it costs.
        icon = r.icon, price = r.price,
        -- A row the page draws as a button, and which mark goes on it.
        button = r.button,
        trigger = r.trigger, owned = r.owned, arena_max = r.arena_max,
        -- What the controls page needs to draw a chip: which color band the
        -- control is in, which key it is on so the board can be lit from the
        -- same list, whether it is the one waiting for a key, and whether it
        -- is the row that puts everything back.
        cat = r.cat, control = r.control, keys = r.keys, fixed = r.fixed,
        arming = r.arming, reset = r.reset,
        pick = (r.go or r.act) ~= nil,
        mark = r.mark and r.mark() or false,
        -- A row that leaves the game gets a real anchor laid over it by the
        -- page. Nothing the client does from its own loop is inside the tap
        -- that asked for it, and a browser will not open a tab for anything
        -- else, so the finger has to land on the anchor rather than on the
        -- canvas. Only the community row carries one.
        link = r.link,
    }
end

local function control_name(id)
    for _, c in ipairs(binds.rows()) do
        if c.id == id then return c.name end
    end
    return nil
end

-- Put `id` on `key`, and say what happened. Returns whether anything moved,
-- which is what the arena sounds.
--
-- A key already spoken for trades: the two controls swap, and the line at the
-- foot says so, because a pilot who put `map` on W and found their burst had
-- gone somewhere would otherwise have to hunt for it. Nothing is ever left
-- without a key, which is the property that makes this safe to do with no
-- confirmation on it at all.
local function bind_to(id, chord)
    M.arming = nil
    local moved, ok = binds.set(id, chord)
    if not ok then
        -- The one refusal worth a sentence: a control that is not ours to
        -- move. Everything else that lands here is a press that changed
        -- nothing, and saying "that is already where it is" to somebody who
        -- pressed the key it is already on is noise.
        M.foot = binds.fixed(id)
            and "escape is how you leave this page; it stays where it is"
            or nil
        return true
    end
    M.save_identity()
    local name = control_name(id)
    -- What was stored, not what was pressed. `chord` is in the order the hand
    -- went down and binds.set files a normalized copy with the modifiers
    -- first, so holding Tab and then Shift left the chip reading Shift+Tab
    -- under a sentence claiming Tab+Shift: the one line whose whole job is to
    -- confirm the binding, disagreeing with the row it confirms.
    local set = binds.chord_of[id] or chord
    if moved then
        M.foot = string.format("%s is on %s; %s took the keys it left",
                               name, keyset.chord(set),
                               control_name(moved) or "")
    else
        M.foot = string.format("%s is on %s", name, keyset.chord(set))
    end
    return true
end

-- A chord arrived while a control was asking for one: everything that was
-- held, in the order it went down, from the page that watched a hand do it.
function M.bind_chord(chord)
    if not M.arming then return false end
    return bind_to(M.arming, chord)
end

-- Escape, while a control is asking. It goes back to where it was, which is
-- the answer that changes nothing, the same as every other question here.
function M.cancel_bind()
    if not M.arming then return false end
    M.arming = nil
    M.foot = nil
    return true
end

-- The next row the arrows stop on, walking one step in `dir` and wrapping.
--
-- A row that is neither a destination nor a value is a readout, and the cursor
-- has no business standing on one: left does nothing from it, right does
-- nothing to it, and on the ship page left is the way out, so walking down
-- from the ship onto the budget bar and pressing left shut the page. Skipped
-- entirely, unless the whole list is readouts, in which case a cursor that
-- refused to move would be worse.
local function next_stop(rows, at, dir)
    local n = #rows
    if n == 0 then return at end
    for _ = 1, n do
        at = (at - 1 + dir) % n + 1
        local r = rows[at]
        if r and (r.go or r.act) then return at end
    end
    return (at - 1 + dir) % n + 1
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
        -- With nothing behind the panel it opens on the games, the page the
        -- client itself opens on, with the cursor in the list rather than on
        -- the tabs: one press from flying.
        --
        -- Over a game it opens on the tab row, because the row is two tabs
        -- long there and the thing a pilot mid-fight most often wants is one
        -- of them. Opening a page first would put a press between them.
        if M.home then
            M.show("play")
        else
            M.stack = {"root"}
            M.sel.root = 1
            M.open = true
        end
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
local function settle(act, asked, by)
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
        M.volume = (M.volume - 1 + (by or 1)) % #VOLUMES + 1
        M.apply_settings()
        M.save_identity()
    elseif act == "music" then
        M.music = (M.music - 1 + (by or 1)) % #MUSICS + 1
        M.apply_settings()
        M.save_identity()
    elseif act == "cap" then
        M.cap = (M.cap - 1 + (by or 1)) % #CAPS + 1
        M.apply_settings()
        M.save_identity()
    elseif act == "do_unfriend" then
        -- Both directions, so a removed pilot does not keep this one on their
        -- list, visible and joinable. See docs/design/friends.md.
        account.friend(asked and asked.who or 0, false)
    elseif act == "do_join_friend" then
        -- The arena's half: this file has no socket. `pending` is the account
        -- number, and arena.script turns it into the instance they are in.
        M.pending = asked and asked.who or 0
        return "join_friend"
    elseif act == "steering" then
        -- Nothing to apply: the arena reads this every frame and the touch
        -- layer redraws from it, so there is no engine state to keep in step
        -- the way sound and frames have.
        M.dpad = not M.dpad
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

-- What there is to do with a friend, on a card, because a row has one press
-- and there are two answers.
--
-- Join first when there is one, since it is what somebody opening this page is
-- usually here for, and it is where the cursor would be if the card had one
-- key. Removing sits under it and says what it does: both edges, so they stop
-- seeing you as well.
function M.ask_friend(who, name, zone, joinable)
    local keys = {}
    if joinable then
        keys[#keys + 1] = {label = "join " .. (zone or "them"),
                           act = "do_join_friend"}
    end
    keys[#keys + 1] = {label = "remove", act = "do_unfriend"}
    keys[#keys + 1] = {label = "never mind"}
    M.ask = {head = name or "This pilot.", keys = keys, sel = #keys, who = who}
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

-- What a card typed into does while the meta-layer thinks about it.
--
-- The card stays up while the answer is in flight and turns into the refusal
-- when there is one, holding what was typed: the next thing anybody does with
-- a refused password is fix it, not retype it. `send` is handed the callback
-- to hang the reply on, and `won` is what to do with a yes, which is the only
-- part that differs between the things sent from here.
--
-- Three details are easy to leave out of a second copy of this and were:
-- the guard against a card that has since been replaced, the flag that stops
-- a second press while the first is in flight, and the trim that keeps a
-- reason which already ends in a full stop from growing another one.
local function send_card(asked, busy, send, won)
    M.ask = asked
    asked.sending = true
    asked.head = busy
    send(function(ok, why)
        -- A different question is up now; this answer is about nothing.
        if M.ask ~= asked then return end
        if ok then
            M.ask = nil
            if won then won() end
            return
        end
        asked.sending = false
        asked.head = string.gsub((why or "That did not work.") .. ".",
                                 "%.%.$", ".")
    end)
end

-- The claim, sent.
function M.send_claim(asked)
    local password = asked and asked.fields and asked.fields[1].value or ""
    send_card(asked, "One moment.", function(done)
        account.claim(password, done)
    end)
end

-- The login, likewise.
function M.send_login(asked)
    local name = asked and asked.fields and asked.fields[1].value or ""
    local password = asked and asked.fields and asked.fields[2]
        and asked.fields[2].value or ""
    send_card(asked, "Signing in.", function(done)
        account.login(name, password, done)
    end, function()
        M.note = nil
        M.adopt_account_name()
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
    -- The same rule for a control waiting on a key, and a harder one: it holds
    -- the whole keyboard while it is up, so left standing behind a shut menu
    -- it would swallow the next press of anything.
    M.arming = nil
    M.foot = nil
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
    -- A control can only be waiting for a key on the page that asked, with
    -- nothing over it. A pointer can leave that page without ever pressing
    -- one, since the keyboard is taken but the mouse is not, so this is where
    -- the state is let go rather than in each of the four ways out.
    if M.arming and (M.at() ~= "controls" or M.ask) then M.arming = nil end
    -- A page the tab row no longer carries is a page you are no longer in.
    -- The hangar is the one that comes and goes: it opens for the twenty five
    -- seconds between matches, and a pilot still standing in it when the
    -- whistle goes would be picking a hull for a match already running, which
    -- is exactly what locking the hull for a match means not doing.
    if #M.stack > 1 then
        local nd2 = NODES[M.stack[2]]
        local top = rows_of(NODES.root)
        local reachable = nd2 ~= nil and nd2.off_rail == true
        for _, r in ipairs(top) do
            if r.go == M.stack[2] then reachable = true break end
        end
        if not reachable then
            M.stack = {"root"}
            M.sel = {}
        end
    end
    if M.at() ~= "controls" then M.foot = nil end
    -- Two pages ask the meta-layer for their contents when they open. Asked
    -- on the edge rather than every frame: a shelf and a week's table are
    -- read while somebody looks at them, and a page nobody is on should cost
    -- the fleet nothing.
    --
    -- "On screen" rather than "entered". At the root the stage previews the
    -- tab under the cursor, so a player who arrows onto upgrades reads the
    -- whole page without the stack ever naming it. It said the shelf was
    -- empty, which is a sentence about the account rather than about the
    -- request that was never sent.
    local at = M.showing()
    local arrived = at ~= was_at
    if arrived then
        if at == "upgrades" then account.refresh_upgrades() end
        if at == "standings" then account.refresh_week() end
        was_at = at
    end
    -- Friends is asked for on two pages rather than one, and again while
    -- either is up.
    --
    -- On its own page for the obvious reason. On the games page because the
    -- row there says how many friends are in a game, and a row that only fills
    -- in once you have opened the page it is advertising can never be the
    -- reason you open it. It said "nobody yet" to a pilot with two friends
    -- flying.
    --
    -- And again on a timer because this is the one page whose answer goes
    -- stale on its own: a friend joins a game or leaves one, and nothing the
    -- pilot reading it does makes that so. The shelf and the week's table only
    -- move when the pilot moves them.
    friends_due = friends_due - (dt or 0)
    if (at == "friends" or at == "play") and (arrived or friends_due <= 0) then
        friends_due = FRIENDS_EVERY
        account.refresh_friends()
    end
    if M.at() ~= "play" then
        zone_synced = false
        -- And forget where the cursor was. Every other page is a place you
        -- left off; this one has a right answer, and it is the game you are in
        -- rather than the row you were reading when you walked away.
        M.sel.play = nil
        return
    end
    if zone_synced or #directory.rows == 0 then return end
    zone_synced = true
    -- Never over a cursor somebody has already moved. The client opens on this
    -- list now, so a player can be arrowing down it while the directory is
    -- still being asked, and a row that jumps out from under them a second
    -- later is worse than one that never moved.
    if M.sel.play and M.sel.play > 1 then return end
    if M.zone == "" then return end
    for i, r in ipairs(directory.rows) do
        if r.zone == M.zone then M.sel.play = i return end
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
                 -- What the page is about, where the tab row does not already
                 -- say it. A name, a trade and a hull to draw.
                 head = nd.head and nd.head() or nil,
                 -- Who is reading this and what they have to spend, which the
                 -- topbar carries at the far end of the tab row. It is the
                 -- same slot the score and the clock take in a match: the
                 -- right-hand end of that row always answers "how am I doing
                 -- in the thing I am in".
                 pilot = {name = M.name, rivets = account.rivets or 0},
                 pilot_hot = M.pilot_hot,
                 carousel_hot = M.carousel_hot,
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
                 -- And for its rows to be laid out under that keyboard as
                 -- chips rather than down a column.
                 chips = nd.chips or false,
                 -- Whether one of them is waiting for a key, which the board
                 -- reads to go dark around it.
                 arming = M.arming ~= nil,
                 foot = M.foot,
                 rows = {}}
    for i, r in ipairs(rows) do
        out.rows[i] = view_row(r, i)
    end
    -- The hangar is two levels of the stack drawn at once: the roster down
    -- the left and the kit of the hull it is standing on beside it. So the
    -- page carries both, and which of them the arrows are in.
    -- The shelf is a grid of cards rather than a list of rows, and the page
    -- says so rather than the drawing guessing from what a row carries.
    if M.at() == "upgrades" and #rows > 0 then out.shelf = true end
    -- The week is a table, and the page draws it as one.
    if M.at() == "standings" and #rows > 0 then out.table = true end
    -- What pressing play would do, beside the list of things to press it on.
    -- The mode list is short and the panel is wide, and the question a player
    -- is actually asking is "where would this put me".
    local previewing = (#M.stack == 1) and rows_of(NODES.root)[sel]
                       and rows_of(NODES.root)[sel].go or nil
    if M.at() == "play" or previewing == "play" then
        out.aside = deploying(M.at() == "play" and sel or (M.sel.play or 1))
    elseif not M.home then
        -- In a match the column beside the page is the match: who is in it and
        -- what they have done, which is what the mock puts there and what a
        -- player opening a menu mid-fight is most likely to want a look at.
        out.aside = {match = true, head = "in this match"}
    elseif M.at() == "pilot" or previewing == "pilot" then
        -- Who you are, beside what you can do about it. The call sign is the
        -- page, and the rows are three things you might do to it.
        out.aside = {
            head = "call sign",
            label = M.name,
            sub = account.claimed and "claimed" or "a guest on this device",
            note = "dealt to you on arrival, and yours until you reroll it. "
                   .. "A name of your own is something to buy once you have "
                   .. "flown enough to want one.",
            foot = account.claimed
                and "this pilot comes back anywhere you sign in"
                or "a password brings this pilot back on any machine; without "
                   .. "one it lives on this one",
        }
    end
    -- The ship page carries the roster as well as the kit: the drawing at its
    -- head is a carousel through every hull, and `rows` is what thirty points
    -- buy on the one it is showing.
    if M.at() == "hangar" then
        out.hulls = {}
        for i, r in ipairs(hull_rows()) do
            out.hulls[i] = view_row(r, i)
        end
        out.hull_sel = M.hull_index()
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
            out.chips = nd2.chips or false
            out.empty = nd2.empty and nd2.empty() or nil
            out.head = nd2.head and nd2.head() or nil
            out.rows = {}
            for i, r in ipairs(rows_of(nd2)) do
                out.rows[i] = view_row(r, i)
            end
            -- A preview of a page is that page, not a different drawing of
            -- the same rows: the hangar previews as a roster beside a kit and
            -- upgrades as its shelf, because what the tab under the cursor
            -- leads to is the thing worth showing.
            if pick.go == "hangar" then
                out.hulls = {}
                for i, r in ipairs(hull_rows()) do
                    out.hulls[i] = view_row(r, i)
                end
                out.hull_sel = M.hull_index()
                out.kit_preview = true
            elseif pick.go == "upgrades" then
                out.shelf = #out.rows > 0
            elseif pick.go == "standings" then
                out.table = #out.rows > 0
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

local function open_external(url)
    if html5 then
        -- A same-tab navigation is not a popup, so phones do not block it
        -- when the canvas reports the press a frame later. The policy pages
        -- carry a Play link back to the game.
        pcall(html5.run, "window.location.assign(\"" .. url .. "\")")
    else
        pcall(sys.open_url, url, {target = "_blank"})
    end
    return nil
end

-- Activate the selected row. Returns an action for the arena, or nil.
-- Press a row, or nudge it.
--
-- `by` is -1 or 1 from left and right on a row that carries a range, and nil
-- from enter. A row with a range is a value rather than a destination, so the
-- arrows set it and enter cycles it, which is what those keys mean everywhere
-- else in the game.
local function activate(by)
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
    if r.act == "kit_step" then
        -- One point spent or taken back. Enter spends, because a hand walking
        -- the list with enter is adding to a ship; the arrows do both.
        --
        -- An add-on wraps. It is drawn as a chip rather than a ladder, so
        -- there are no lower rungs to press and a chip already at its ceiling
        -- answered nothing: an add-on could be put on with a pointer and only
        -- taken off with the arrow keys, which is a control with one
        -- direction. At the top, the next press takes it off.
        local at = (M.kit and M.kit[r.value + 1]) or 0
        local top = kit_ceiling()[r.value + 1] or 0
        if not by and r.group == "weapons" and at > 0 and at >= top then
            if M.kit_set(r.value, 0) then
                M.note = nil
                return "kit"
            end
            return nil
        end
        if M.kit_step(r.value, by or 1) then
            M.note = nil
            return "kit"
        end
        -- Refused, and a press that does nothing looks the same whatever the
        -- reason, so the foot of the page says which. A slot the arena has and
        -- the account does not is the one worth pointing somewhere.
        if (by or 1) > 0 then
            if top == 0 and (r.arena_max or 0) > 0 then
                M.note = "not yours yet: it is on the upgrades page"
            elseif at < top then
                M.note = "no kit points left"
            end
        end
        return nil
    elseif r.act == "hull" then
        -- The carousel at the head of the ship page. Left and right turn it,
        -- which is what the arrows either side of the drawing do; enter asks
        -- for the cell it is showing.
        if by then return (M.click_carousel(by)) end
        if r.value == nil then return "spectate" end
        M.pending = r.value
        return "ship"
    elseif r.act == "ship" then
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
    elseif r.act == "inspect_pilot" then
        -- The cursor is already on the row: standing on one is what fills the
        -- panel beside the table, so a press has nothing left to do. It is an
        -- action rather than nothing so that the row publishes a hit box and
        -- the mouse can move the cursor here at all.
        M.note = nil
        return nil
    elseif r.act == "befriend" then
        -- Adding is one press and nothing else: it is not destructive, it is
        -- reversible from the same page, and the pilot doing it is looking at
        -- the name. The reply is the whole page back, so the row moves from
        -- one section to another without a second request.
        account.friend(r.value, true)
        M.note = nil
        return nil
    elseif r.act == "friend_card" then
        M.ask_friend(r.value, r.label, r.zone, r.joinable)
        return nil
    elseif r.act == "buy" then
        -- The meta-layer prices it, checks the wallet and raises the ceiling
        -- in one call. Nothing here decides whether it can be afforded: this
        -- asks, and the reply is the answer.
        M.pending = r.value
        return "buy"
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
    elseif r.act == "bind" then
        -- The row stops saying where its control is and starts asking where
        -- it should go. Everything about that state is one field: the page
        -- reads it to draw the board dark and the chip empty, and
        -- `arena.script` reads it to hand the next key here instead of to the
        -- cursor.
        if r.fixed then
            M.note = "escape is how you leave this page; it stays where it is"
            return nil
        end
        M.arming = r.control
        M.note = nil
        -- What the page is waiting for, said once. The chip's key column has
        -- gone empty and the board has gone dark around one key, which says
        -- something is being asked without saying what may be answered: two
        -- keys held together are a binding as much as one is, and nothing on
        -- screen could show that.
        M.foot = string.format(
            "press a key for %s, or two together; escape leaves it alone",
            r.label or "it")
        return nil
    elseif r.act == "defaults" then
        binds.reset()
        M.save_identity()
        M.foot = "every key is back where it started"
        return nil
    elseif r.act == "privacy" then
        return open_external("https://vectorwake.net/privacy")
    elseif r.act == "terms" then
        return open_external("https://vectorwake.net/terms")
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
        -- Mid-game the roll is also a respawn, because a new name is a new
        -- pilot and the seat is rejoined to wear it. Said on the card rather
        -- than discovered: the one thing this row does is ask first.
        local head = "your call sign is " .. M.name
        if not M.home then
            head = head .. ". A new one respawns your ship"
        end
        M.confirm(head, {{label = "roll", act = "reroll"}, {label = "keep"}})
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
    return settle(r.act, nil, by)
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

    -- The tab row reads its own axis, which is the row's own: left and right
    -- walk the tabs, down and enter go into the page under them, and up does
    -- nothing because there is nothing above a tab row.
    --
    -- This was up and down while the tabs were a column down the left. The
    -- keys follow the drawing rather than the tree, which is what makes the
    -- same five inputs work on a keyboard, a d-pad and a thumb without a
    -- second layout: an arrow means the direction it points.
    if #M.stack == 1 then
        if keys.back then return escape() end
        if keys.left then
            M.sel[id] = (row_index(rows) - 2) % n + 1
            return nil, true
        end
        if keys.right then
            M.sel[id] = row_index(rows) % n + 1
            return nil, true
        end
        if keys.go or keys.down then return activate(), true end
        return nil, false
    end

    -- A grid reads its own arrows. Everywhere else right is enter, which is
    -- what a one-column list wants and exactly wrong on a page laid out in
    -- four: pressing right to look at the hull beside this one flew it
    -- instead, and down, which should have gone to the row below, went one
    -- ship to the right. Enter is still the only thing that picks.
    if nd.grid and #M.stack > 1 and n > 0 then
        -- The hull page is as wide as the window lets it be and says so every
        -- frame; the controls page is three across whatever the window does,
        -- because a chip is a name and a key rather than a drawing and four of
        -- them across a narrow panel would put the key back under the name.
        local cols = math.max(1, math.min(nd.cols or M.cols, n))
        local i = row_index(rows)
        if keys.back then return escape() end
        -- The line at the foot is about the press that put it there. Moving
        -- the cursor is the next press, so it goes.
        if keys.up or keys.down or keys.left or keys.right then
            M.foot = nil
        end
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
            -- Off the top row and back to the tabs, which is what up means
            -- everywhere in this menu now. Wrapped round to the bottom of the
            -- grid instead, a hand on the arrows could reach the page and
            -- never leave it.
            if i <= cols then return back() end
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
    -- A row carrying a range is a value rather than a destination, so left and
    -- right set it. Everywhere else left is the way back and right is enter,
    -- which is what a one-column list of places wants.
    local here = rows[row_index(rows)]
    local ranged = here ~= nil and here.choice ~= nil and here.act ~= nil
    if keys.left then
        if ranged then return activate(-1), true end
        return back()
    end
    if keys.right then
        if ranged then return activate(1), true end
        return activate(), true
    end

    if keys.up then
        -- Off the first row and back to the tabs. A list that wrapped from
        -- its head to its foot had no way back up to the row above the page.
        if row_index(rows) == 1 then return back() end
        M.sel[id] = next_stop(rows, row_index(rows), -1)
        return nil, true
    end
    if keys.down then
        M.sel[id] = next_stop(rows, row_index(rows), 1)
        return nil, true
    end
    if keys.go then return activate(), true end
    return nil, false
end

-- An arrow beside the ship, pressed: the next ship along, wrapping. The
-- roster is a carousel rather than a list, so this is the whole of moving
-- through it with a pointer. Arrows on the keyboard do the same thing.
function M.click_carousel(dir)
    local hulls = hull_rows()
    local n = #hulls
    if n == 0 then return nil, false end
    M.hull_at = (M.hull_index() - 1 + dir) % n + 1
    local r = hulls[M.hull_at]
    -- Only where the cell is a hull. The last one is sitting out, which has
    -- no kit to edit, so the ladders below go on showing the ship the pilot
    -- was last looking at rather than emptying.
    --
    -- Through `open_kit`, which loads that hull's own saved kit. Setting the
    -- class alone left the previous hull's kit under the new drawing, because
    -- the page only re-reads when the two disagree: turning the carousel
    -- carried an Apex build onto a Wedge and would have saved it there.
    if r and r.value then M.open_kit(r.value) end
    M.note = nil
    -- At home, turning the carousel is choosing: what a hull cell means there
    -- is the ship you will arrive in, and both that and sitting out are
    -- remembered and reversible by turning again. A player who spins to a
    -- ship, likes it and walks away should be flying it.
    --
    -- In a game the same turn is a browse. There a hull ask is a request the
    -- room answers and sitting out despawns you, so the press is what commits
    -- and browsing costs nothing.
    if M.home and r then
        M.pending = r.value
        return (r.act == "spectate") and "spectate" or "ship", true
    end
    return nil, true
end

-- Which arrow the pointer is on, so it can light up.
M.carousel_hot = nil

-- One pip of a ladder, pressed. The row it belongs to takes the cursor, and
-- the slot goes to that step. See `M.kit_set`.
function M.click_kit_at(index, level)
    local rows = rows_of(node())
    local r = rows[index]
    if not r or r.act ~= "kit_step" then return nil, false end
    M.sel[M.at()] = index
    if M.kit_set(r.value, level) then
        M.note = nil
        return "kit", true
    end
    return nil, true
end

-- The call sign in the corner of the tab row, pressed. It is a destination
-- like a tab stop, so it behaves like one: home first, then into the page.
function M.click_pilot()
    if not M.home then return nil, false end
    M.stack = {"root", "pilot"}
    M.note = nil
    return nil, true
end

-- Whether the pointer is on that name, so it can be underlined the way a lit
-- tab is. The arena sets it from the same hit list the press comes off.
M.pilot_hot = false

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

-- Is there still a row there?
--
-- A press is tested against hit boxes the previous frame published, and some
-- of these lists are rebuilt underneath them: the games list is refreshed from
-- the directory for as long as it is on screen, so a room can leave it between
-- the drawing and the press. The cursor clamps an index past the end onto the
-- last row, which turned a click on a row that no longer exists into a click
-- on whatever had moved into the bottom of the list -- and on the home screen
-- there is no confirmation card between that and joining a game nobody picked.
-- The hover path has always checked this; the two click paths did not.
local function row_at(index)
    local rows = rows_of(node())
    return index and rows[index] or nil
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
    if not row_at(index) then return nil, false end
    M.sel[id] = index
    return activate(), true
end

-- A pointer landed on a row the interface published.
function M.click(index)
    if not M.open then return nil, false end
    if not row_at(index) then return nil, false end
    M.sel[M.stack[#M.stack]] = index
    return activate(), true
end

-- A key on the drawn board was clicked. It goes to whichever control is
-- asking, and to the one under the cursor when none is: the picture is the
-- same list as the chips, so pointing at a key is the other half of the
-- gesture that pointing at a chip started.
--
-- No arming step in that second case, on purpose. Arming exists because a
-- keyboard has to be told which of its own presses is an answer rather than a
-- control; a click carries the key it means, so there is nothing to be told.
function M.click_key(key)
    if not M.open then return nil, false end
    local id = M.arming
    if not id then
        local rows = rows_of(node())
        local r = rows[row_index(rows)]
        id = r and r.control
    end
    if not id then
        M.foot = "pick a control first, then a key to put it on"
        return nil, true
    end
    -- One key, since that is what a click carries. A chord is two keys held
    -- together and there is no holding in a click, so the keyboard is the only
    -- way to make one; the page says so while it is waiting.
    return nil, bind_to(id, {key})
end

-- The x on the panel. It shuts the menu rather than stepping back a level,
-- which is what a cross means everywhere else, and it is drawn only where
-- there is a game behind to shut it onto.
function M.click_close()
    if not M.open then return nil, false end
    return nil, M.close()
end

return M
