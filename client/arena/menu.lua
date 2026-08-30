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
-- A room actually playing behind the panel at home, rather than a starfield
-- and a zone name this client remembers from last time. Set by the arena each
-- frame, and declared here because it is read before the first one.
M.scenery = false
-- What you will arrive as, which the ship page sets and a join carries. It is
-- remembered like the hull is, because it is the same choice: a player who
-- came to watch is still there to watch after a reload.
M.spectate = false
M.pending = nil         -- the hull a row just asked for
M.chosen = nil          -- the game a row just asked for
-- Which game a press asked to be in, and nothing while none is waiting.
--
-- A row of the games list is one act, whatever this client is: be in that
-- zone. Where it already is, that is answered on the spot and the panel goes;
-- where it is not, the stands dial the zone and go on dialing while a
-- network or an arena is down, and the panel goes when the client is actually
-- there. So a press is a thing the client is now trying to do rather than a
-- thing it has done, and this is what it is trying.
--
-- Cleared when it lands, when the menu closes, and when a press names
-- somewhere else. See `M.arrived`.
M.await = nil
-- And which of its rooms, by the number the server gave that room, when a row
-- named one. Nil is what every arrival through the games list says, and it
-- means "wherever the fill ladder puts me".
M.chosen_room = nil
-- How deep into the column's pages a hand has walked. Empty is the bare three
-- stops, which is the ordinary state: one entry is the page a stop opened, two
-- is a page that page opened. That is the whole depth of this tree.
M.stack = {}
M.note = nil            -- set by the arena when a connection fails
M.screen = nil          -- the drawable and its insets, for the about page
-- How the line is behaving, in bars, as the frame layer smooths it. Written by
-- the arena and read by the about page.
M.link_bars = 4
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
-- How often a guest with nothing recorded yet re-asks for their career, which
-- is the figure the guest warning arms on. Slow, because what it is watching
-- for happens once in an account's life.
local career_due = 0
local CAREER_EVERY = 10
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

-- Whether the ship page's answer is currently "no hull". In a game that is
-- what the connection says you are; on the home screen it is what you have
-- asked to arrive as. One question, two places it can be answered from.
function M.spectating()
    if M.home then return M.spectate end
    return M.watching
end

-- The three things this client can be while the menu is up, said in the two
-- flags the arena sets every frame.
--
-- Flying: a seat of your own in a room. Watching: a room on screen with no
-- seat of yours in it, which is the stands at home and a benched pilot in a
-- game. Adrift: no room at all, because the fleet is down or the network is.
function M.flying()
    return not M.home and not M.watching
end


-- The client is in a zone. Called by the arena whenever a room answers, which
-- is the one moment a press that was waiting on one can be finished.
function M.arrived(zone)
    if M.await == nil or zone ~= M.await then return false end
    M.await = nil
    if not M.open then return false end
    M.close()
    return true
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
    {"Apex", "dart", "long and narrow, with a larger broadside target"},
    {"Wedge", "delta", "a wide delta that turns edge-on to shrink"},
    {"Chord", "bow", "the widest and shortest hull, almost entirely beam"},
    {"Anvil", "slab", "blunt and square, with no especially small angle"},
    {"Cipher", "knife", "the longest and narrowest hull in the roster"},
    {"Facet", "wedge", "a compact pentagon on a square footprint"},
    {"Lattice", "cross", "a square truss that turns anywhere it fits"},
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

-- The wake the ship leaves, as this client draws it: the flair section's
-- one working choice today. Client-side and cosmetic, like the trail
-- itself: nothing about it crosses the wire, so what other pilots see is
-- their own client's standard ribbon whatever is picked here.
M.wake = 0
M.WAKES = {"standard", "long", "none"}

function M.save_identity()
    pcall(sys.save, SAVE, {
        name = M.name, class = M.class, volume = M.volume, music = M.music,
        cap = M.cap, zone = M.zone, spectate = M.spectate,
        help_prompt_seen = M.help_prompt_seen,
        -- The wake, with the rest of what this pilot looks like.
        wake = M.wake,
        -- Which charge the first key throws, which is a preference about a
        -- keyboard and belongs beside the bindings.
        charge_flip = M.charge_flip,
        -- One build a hull, written as slot and count pairs so a save that
        -- outlives a change to the slot space carries nothing it cannot
        -- read back. A hull the pilot has never edited is simply absent.
        builds = M.builds,
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
        M.wake = (type(d.wake) == "number" and d.wake >= 0
                  and d.wake < #M.WAKES) and math.floor(d.wake) or 0
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
        M.charge_flip = d.charge_flip == true
        -- The builds, read back a slot at a time and refused where a number
        -- does not belong. A save is a file on somebody's disk, and the slot
        -- space it was written against may not be this build's: anything out
        -- of range is dropped rather than trusted, and the arena fits what
        -- survives to its own ceilings anyway.
        M.builds = {}
        if type(d.builds) == "table" then
            -- Read straight rather than through `simn`, which this file
            -- declares below here and which would be a nil global at this
            -- point in it.
            local core = _G.sim
            local slots = (core and tonumber(core.SLOT_COUNT)) or 23
            for cls, mine in pairs(d.builds) do
                if type(cls) == "number" and HULLS[cls + 1]
                   and type(mine) == "table" then
                    local kept = {}
                    for slot, n in pairs(mine) do
                        if type(slot) == "number" and type(n) == "number"
                           and slot >= 0 and slot < slots and n > 0 then
                            kept[math.floor(slot)] = math.floor(n)
                        end
                    end
                    M.builds[math.floor(cls)] = kept
                end
            end
        end
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

-- The slot space's shape, off the core.
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

-- --- the roster ------------------------------------------------------------
--
-- A hull owns its flight row, its gun and its bomb; a pilot owns what those
-- carry, bought with seven credits at one credit a step. So the page is both
-- a picker and an editor, and the two are the same page because the thing
-- being edited is the ship being picked.
--
-- What stood here before this was thirty points against an arena ceiling and
-- an account's entitlements, a shelf to buy rungs from, a wallet to buy them
-- with, and named builds to save the result under. None of that comes back.
-- There is nothing to own, nothing to buy, nothing to name and nothing to
-- price: everything is reachable by everybody, and a step costs the same as
-- every other step. See decision 100.

-- What a hull flies with, over the flat slot space, or nil before the core
-- has a settings table to read it from.
local function class_kit(cls)
    local core = _G.sim
    return core and core.class_kit and core.class_kit(cls) or nil
end

-- How high one slot goes for a hull, which is where a stepper stops. The
-- core's own answer, so a key that looks pressable is one the arena will act
-- on. Zero before the core has settings, which reads as a row that cannot be
-- stepped rather than one that steps into nothing.
local function slot_cap(cls, slot)
    local core = _G.sim
    return core and core.slot_cap and core.slot_cap(cls, slot) or 0
end

-- What a pilot has to spend. One number, and the only one on this page.
local function credits()
    return simn("KIT_CREDITS", 7)
end

-- --- builds ----------------------------------------------------------------
--
-- One remembered build a hull, on this device, beside the wake and the key
-- bindings rather than in an account.
--
-- That is the whole of the storage, and it is deliberate. A build is seven
-- ones over a dozen slots: it is worth remembering so a pilot does not spend
-- it twice, and it is not worth a table, a route, a migration and a login to
-- carry it between machines. Nothing is owned, so there is nothing an
-- account could be protecting.
--
-- Keyed by class, each a sparse map of slot to count. Absent means this hull
-- has never been edited, which is not the same as an empty build: absent
-- flies the hull's own profile and empty flies a stripped hull, and a pilot
-- can ask for either.
M.builds = {}

-- What this hull flies, as the vector the wire wants: the pilot's build if
-- they have one, otherwise the hull's own profile.
function M.build_of(cls)
    local out = {}
    local n = simn("SLOT_COUNT", 23)
    local mine = M.builds[cls]
    local row = class_kit(cls)
    for slot = 0, n - 1 do
        if mine then
            out[slot] = mine[slot] or 0
        else
            out[slot] = row and row[slot + 1] or 0
        end
    end
    return out
end

-- What that build costs, which is the sum of it.
function M.build_cost(cls)
    local total = 0
    for _, n in pairs(M.build_of(cls)) do total = total + n end
    return total
end

-- Credits still in hand for this hull.
function M.build_free(cls)
    return math.max(0, credits() - M.build_cost(cls))
end

-- Whether this hull is flying something other than its own profile, which is
-- the one thing the roster says about a build without opening it.
function M.build_edited(cls)
    return M.builds[cls] ~= nil
end

-- Step one slot, by one credit, in the direction asked.
--
-- Refused rather than clamped where it cannot happen: up with nothing left
-- to spend, up at the slot's own ceiling, down at nothing. A refusal is what
-- lets the drawing dim an arrow that would do nothing, since both ask this
-- same question.
--
-- The first edit copies the hull's profile into a build, so a pilot who
-- steps one slot keeps everything else the ship came with.
function M.build_step(cls, slot, dir)
    local have = M.build_of(cls)
    local at = have[slot] or 0
    local want = at + dir
    if want < 0 then return false end
    if dir > 0 then
        if want > slot_cap(cls, slot) then return false end
        if M.build_free(cls) < 1 then return false end
    end
    local mine = M.builds[cls]
    if not mine then
        mine = {}
        for k, n in pairs(have) do
            if n > 0 then mine[k] = n end
        end
        M.builds[cls] = mine
    end
    mine[slot] = want > 0 and want or nil
    M.save_identity()
    M.send_build(cls)
    return true
end

-- Back to the hull's own profile, which is the whole of the build manager.
function M.build_reset(cls)
    if not M.builds[cls] then return false end
    M.builds[cls] = nil
    M.save_identity()
    M.send_build(cls)
    return true
end

-- Tell the arena what this pilot is flying.
--
-- Sent whenever a build moves and again with every hull pick, because the
-- arena reads a build naming a hull you are not in as the hull change
-- carrying it: one message says both, so a pilot never flies one tick of the
-- wrong ship. Silent where there is no room to tell.
function M.send_build(cls)
    if not net.set_kit then return false end
    return net.set_kit(cls, M.build_of(cls)) and true or false
end

-- What one step of each flight stat is worth to a hull, or nil. Zero means a
-- row that would take a credit and change nothing.
local function class_up_step(cls)
    local core = _G.sim
    return core and core.class_up_step and core.class_up_step(cls) or nil
end

-- What each slot does, in one sentence, for the row a pilot is standing on.
--
-- About the slot rather than about its current setting, so the sentence is
-- true at every count and the page never has to rewrite it as a number
-- moves. Kept beside the roster because it is the same kind of writing: what
-- a thing is, said once, in the words a player would use.
local SLOT_NOTES = {
    spray = "How many rounds one pull of the trigger throws.",
    gun_bounce = "Rounds come off walls instead of ending on them.",
    gun_freeze = "What a round hits stops recharging for a moment.",
    gun_prox = "Rounds go off near a hull rather than only on one.",
    gun_shrapnel = "Each round ends by throwing fragments of its own.",
    gun_push = "Rounds shove what they hit.",
    bomb_bounce = "The bomb comes off walls instead of ending on them.",
    bomb_freeze = "The blast stops whoever it catches recharging.",
    bomb_prox = "A fuse, so a near miss counts.",
    bomb_shrapnel = "Fragments thrown by the blast, each carrying the "
        .. "gun's damage.",
    bomb_push = "The blast shoves what it catches.",
    bomb_spray = "How many bombs one throw puts in the air.",
    repel = "A push that answers rounds already on their way to you.",
    burst = "A ring of rounds thrown out around you.",
    energy = "How deep the bar is that flying and firing spend.",
    recharge = "How fast that bar fills again.",
    speed = "How fast this hull will run.",
    thrust = "How hard it accelerates.",
    rotation = "How quickly it comes round.",
    gun_level = "Which gun off this hull's own ladder it fires.",
    bomb_level = "Which bomb off this hull's own ladder it throws.",
}

local UP_NAMES = {"energy", "recharge", "speed", "thrust", "rotation"}

-- The rows the tuning panel draws for a hull: a section head, then a row per
-- slot that hull can actually spend on, then the way back to its own row.
--
-- Which rows exist is the core's answer rather than a list written here. A
-- slot whose ceiling is zero is a slot this hull cannot reach, so a hull with
-- no bomb rack has no bomb section at all and nobody has to remember to hide
-- one; a stat whose step is zero would take a credit and change nothing, so
-- it is not offered either. That is what keeps this page honest for a zone
-- nobody has written yet.
--
-- A row is a toggle where its ceiling is one and a stepper otherwise, which
-- is the same rule said in the interface: on and off is a switch, and
-- anything you can have more of counts.
function M.tune_rows(cls)
    local rows = {}
    local mine = M.build_of(cls)
    local trig = simn("TRIG_COUNT", 2)
    local mods = simn("MOD_COUNT", 6)
    local mod0 = simn("SLOT_MOD0", 7)
    local ch0 = simn("SLOT_CHARGE0", 19)
    local lvl0 = simn("SLOT_LEVEL0", 5)

    -- One section's worth of rows, added under its own head only if it has
    -- any. A hull with no bomb rack has no bomb rows, and what it must not
    -- have is the word BOMB standing over nothing.
    local function section(label, slots)
        local made = {}
        for _, it in ipairs(slots) do
            local slot, label2, note = it[1], it[2], it[3]
            local cap = slot_cap(cls, slot)
            if cap >= 1 then
                local at = mine[slot] or 0
                made[#made + 1] = {
                    kind = "slot", slot = slot, label = label2, note = note,
                    value = at, cap = cap, toggle = cap == 1,
                    -- What the arrows may do, asked the same way the act
                    -- asks it, so an arrow drawn live is one that works.
                    can_up = at < cap and M.build_free(cls) >= 1,
                    can_down = at > 0,
                }
            end
        end
        if #made == 0 then return end
        rows[#rows + 1] = {kind = "sect", label = label}
        for _, r in ipairs(made) do rows[#rows + 1] = r end
    end

    local step = class_up_step(cls)
    local flight = {}
    for u = 1, #UP_NAMES do
        if step and (step[u] or 0) ~= 0 then
            flight[#flight + 1] = {u - 1, M.titled(UP_NAMES[u]),
                                   SLOT_NOTES[UP_NAMES[u]]}
        end
    end
    section("flight", flight)

    for t = 0, trig - 1 do
        local word = t == 0 and "gun" or "bomb"
        -- The rung first: which weapon off the hull's own ladder, before
        -- what that weapon carries.
        local slots = {{lvl0 + t, "Rung", SLOT_NOTES[word .. "_level"]}}
        for m = 0, mods - 1 do
            local mod = pal.MODS[m + 1]
            local name = mod and (mod.title or mod.name)
                or ("add-on " .. m)
            slots[#slots + 1] = {mod0 + t * mods + m, M.titled(name),
                                 SLOT_NOTES[word .. "_"
                                            .. (mod and mod.name or m)]}
        end
        section(word, slots)
    end

    local rack = {}
    for k = 0, simn("MAX_CHARGES", 4) - 1 do
        local c = pal.CHARGES[k + 1]
        rack[#rack + 1] = {ch0 + k, M.titled(c and c.name or ("charge " .. k)),
                           SLOT_NOTES[c and c.name or ""]}
    end
    section("rack", rack)

    rows[#rows + 1] = {kind = "reset", label = "Reset",
                       on = M.build_edited(cls)}
    return rows
end

-- A slot's name as the page says it: the roster's own word, capitalized,
-- because these are the names of weapons rather than sentences about them.
function M.titled(word)
    return (word:gsub("^%l", string.upper))
end

-- A hull's flight, in the core's own units, as five numbers.
local function class_flight(cls)
    local core = _G.sim
    if not (core and core.class_flight) then return nil end
    local speed, thrust, rot, energy, recharge = core.class_flight(cls)
    if not speed then return nil end
    return {speed, thrust, rot, energy, recharge}
end

-- Where a hull sits on each of the five rows, as a share of the roster's own
-- range.
--
-- A share rather than a figure. The units are the core's, five different
-- scales none of which a player reads, and what the page is answering is
-- "faster than what": a bar against the rest of the roster says that and a
-- number in Q16 pixels a tick does not. A row where every hull is equal
-- reads as a full bar on all seven rather than as a divide by zero.
local function flight_bars(cls)
    local mine = class_flight(cls)
    if not mine then return nil end
    local lo, hi = {}, {}
    for i = 1, 5 do lo[i], hi[i] = math.huge, -math.huge end
    for c = 0, #HULLS - 1 do
        local row = class_flight(c)
        if row then
            for i = 1, 5 do
                lo[i] = math.min(lo[i], row[i])
                hi[i] = math.max(hi[i], row[i])
            end
        end
    end
    local out = {}
    for i = 1, 5 do
        local span = hi[i] - lo[i]
        out[i] = span > 0 and ((mine[i] - lo[i]) / span) or 1
    end
    return out
end

-- Which key a carried charge lands on: the first kind a kit holds is on the
-- first charge key, the second on the second, in the order the core numbers
-- the kinds. Named off the controls list rather than written down here, so a
-- rebound key says what it actually is.
-- Which of the two the arrows and the keys call first.
--
-- The kit carries counts by kind and the core numbers the kinds, so without
-- this the first key always throws the lower-numbered one, whatever the pilot
-- would rather have. It is a preference about a keyboard rather than a fact
-- about a ship, so it lives here and on this device, beside the bindings it is
-- really part of.
M.charge_flip = false

-- The kinds this hull carries, in the order the keys spend them.
local function charge_order()
    local up = simn("UP_COUNT", 5)
    local trig = simn("TRIG_COUNT", 2)
    local first = simn("SLOT_CHARGE0", up + trig + trig * simn("MOD_COUNT", 6))
    local kit = class_kit(M.class or 0) or {}
    local out = {}
    for k = 0, simn("MAX_CHARGES", 4) - 1 do
        if (kit[first + k + 1] or 0) > 0 then out[#out + 1] = first + k end
    end
    if M.charge_flip and #out > 1 then out[1], out[2] = out[2], out[1] end
    return out
end



-- The two of them exchanged, which is the whole of what the row does.
-- Nothing about the ship changes: the same two kinds are carried in the same
-- numbers, and the keys that throw them trade places.
function M.swap_charges()
    if #charge_order() < 2 then return nil, false end
    M.charge_flip = not M.charge_flip
    M.save_identity()
    return nil, true
end




-- What a ship looks like and which key throws which charge: the two things
-- a pilot decides that are not about how a ship fights.
--
-- They stood under the roster on the drawer's ship page while there was one.
-- The roster is the landing's ship stop now, and these did not go with it:
-- the wake is cosmetic and the charge order is a preference about a keyboard,
-- and a panel a player opens to spend credits is not where either belongs.
-- Settings is what a preference has always been for.
local function flair_rows()
    local rows = {}
    rows[#rows + 1] = {
        label = "wake", sect = "ship",
        help = "The trail this ship leaves, as your client draws it.",
        detail = M.WAKES[M.wake + 1],
        act = "wake",
        choice = function() return M.wake + 1, #M.WAKES end,
    }
    -- Absent on a hull carrying one kind of charge or none, where there is
    -- nothing to trade.
    local order = charge_order()
    if #order > 1 then
        local names = {}
        for _, slot in ipairs(order) do
            local k = slot - simn("SLOT_CHARGE0",
                                  simn("UP_COUNT", 5) + simn("TRIG_COUNT", 2)
                                  + simn("TRIG_COUNT", 2)
                                    * simn("MOD_COUNT", 6))
            local c = pal.CHARGES[k + 1]
            names[#names + 1] = c and c.name or ("charge " .. k)
        end
        rows[#rows + 1] = {
            label = "charge keys", sect = "ship",
            help = "Which of the two keys throws which kind.",
            detail = names[1] .. " first",
            act = "swap_charges",
            choice = function() return M.charge_flip and 2 or 1, 2 end,
        }
    end
    return rows
end

-- What the landing's ship stop says you will arrive as: the hull you fly, or
-- that you are sitting out.
--
-- It named a build. A build was thirty points under a name of the pilot's
-- own, and there are none any more: what you arrive as is a ship off the
-- roster.
function M.landing_ship()
    if M.spectating() then return "spectate" end
    local h = HULLS[(M.class or 0) + 1]
    return h and h[1] or "ship"
end

-- Everything the ship stop's panel draws, for one hull.
--
-- One hull at a time rather than the seven as a list. A list of seven with
-- five bars and a build apiece is a page wearing a list's clothes, and the
-- thing a player is actually doing here is looking at one ship and deciding
-- whether to fly it. Left and right walk the roster; what they walk is a
-- ship, its flight against the rest of the roster, the credits it has spent,
-- and the rows that spend them. See decision 100.
--
-- Sitting out is the last page, past the roster, and it carries no bars and
-- no rows because there is no ship to say anything about.
function M.ship_panel(at)
    local n = #HULLS
    at = at or (M.spectating() and n or (M.class or 0))
    if at < 0 then at = n end
    if at > n then at = 0 end
    if at >= n then
        return {at = at, pages = n + 1, watching = true, label = "spectate",
                note = "watch the room from nobody's cockpit"}
    end
    local h = HULLS[at + 1]
    return {
        at = at, pages = n + 1, watching = false, class = at,
        label = h[1], detail = h[2],
        bars = flight_bars(at),
        -- The purse, as two numbers the drawing turns into chips.
        free = M.build_free(at), credits = credits(),
        rows = M.tune_rows(at),
        -- Whether this is the ship you are flying, which the panel says by
        -- lighting its name rather than with a word.
        mine = not M.spectating() and M.class == at,
    }
end

-- How many hulls the roster holds, which is also the page sitting out is on.
function M.hull_count()
    return #HULLS
end

-- Which page the panel opens on: the ship you are flying, or sitting out
-- where that is what you have chosen. The one place that default is written
-- down, so the drawing and the walking agree about where a fresh panel is.
function M.panel_home()
    if M.spectating() then return #HULLS end
    return M.class or 0
end

-- Step the panel one ship, wrapping at either end, and answer where it
-- landed. Nothing is chosen by walking: a pilot looking at an Anvil has not
-- climbed into one until they press.
function M.ship_page(at, dir)
    local n = #HULLS
    local to = (at or 0) + dir
    if to < 0 then to = n end
    if to > n then to = 0 end
    return to
end

-- The rows that stop opens: every ship in the roster, and sitting out as the
-- last answer.
function M.landing_ships()
    local rows = {}
    for i, h in ipairs(HULLS) do
        rows[#rows + 1] = {label = h[1], value = i - 1,
                           here = not M.spectating() and M.class == i - 1}
    end
    rows[#rows + 1] = {label = "spectate", value = "spectate",
                       here = M.spectating()}
    return rows
end

-- The rows the landing's account stop opens: everything this client can do
-- about who it is, and nothing about how it has flown.
--
-- This list is the whole of the account interface now. It was a page in the
-- drawer, reached by a tab and by the call sign in the head, carrying the
-- career over these same acts; the career went with it to the site's own
-- /pilots, and what is left is short enough to be a list you open from the
-- one screen an account is worth editing on. See decision 99.
--
-- Two groups with a rule between them: what you can do to the account you
-- are, then how to be a different one. A guest's first row is the offer,
-- since it is the only one that keeps what they are carrying, and it wears
-- the same green the invite band does.
--
-- Signing up and claiming this account are one act, not two. The server has
-- one endpoint for it, `/v1/claim`, and what it does is put a password on
-- the account this client already holds: there is no second act that makes a
-- fresh account and signs it up, because a fresh account is what a guest
-- already has. So it is one row, and the word on it is the player's, "sign
-- up", rather than the endpoint's.
--
-- Nothing at all without a meta-layer to talk to, except the reroll, which
-- has an offline answer of its own: no account layer means no account to
-- sign up to, and rows that cannot work are worse than a short list.
function M.account_rows()
    local rows = {}
    if account.base == "" then
        rows[#rows + 1] = {label = "new name", act = "reroll"}
        return rows
    end
    if account.claimed then
        rows[#rows + 1] = {label = "set password", act = "claim"}
        rows[#rows + 1] = {label = "new name", act = "reroll"}
        rows[#rows + 1] = {rule = true}
        rows[#rows + 1] = {label = "log off", act = "logout"}
        return rows
    end
    rows[#rows + 1] = {label = "sign up", act = "claim", offer = true,
                       note = "keep your points"}
    rows[#rows + 1] = {label = "new name", act = "reroll"}
    rows[#rows + 1] = {rule = true}
    rows[#rows + 1] = {label = "log in", act = "enter_login"}
    return rows
end

-- A press on a ship in that list: arrive as it. The same path the roster's
-- own row takes, so the choice reaches the arena through the "ship" act the
-- caller runs; picking a ship also means arriving in one, so a remembered
-- spectate comes off here rather than surviving to make the deploy invisible.
function M.pick_profile(at)
    if at == "spectate" then
        M.spectate = true
        M.save_identity()
        return "spectate"
    end
    if type(at) ~= "number" or not HULLS[at + 1] then return nil end
    M.spectate = false
    M.pending = at
    M.save_identity()
    -- And what to fly it with, in the same breath. The arena reads a build
    -- naming a hull you are not in as the hull change carrying it, so this
    -- one message is the whole of picking a ship: without it a pilot would
    -- arrive on the hull's own profile and be moved onto their own build a
    -- tick later, which is a flicker on every pick.
    M.send_build(at)
    return "ship"
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

local NODES = {
    -- The sides, one row each, in the order the zone scores them.
    --
    -- A list rather than a value stepped left and right, which is what the
    -- side row was while a room held two of them. Arrows walk: in a zone
    -- holding three, reaching the third means crossing the second, and a
    -- pilot who wanted the third has joined the second on the way. A row
    -- apiece says them all at once, marks the one you fly for, and puts any
    -- other one press away.
    side = {rows = team_rows},

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
             help = "Effects, warnings, and weapon audio.",
             detail = function() return VOLUMES[M.volume][2] end,
             choice = function() return M.volume - 1, #VOLUMES - 1 end,
             act = "volume"},
            {label = "music", help = "Music in the menus and the arena.",
             detail = function() return MUSICS[M.music][2] end,
             choice = function() return M.music - 1, #MUSICS - 1 end,
             act = "music"},
            {label = "frames", sect = "video",
             help = "Limit rendering to reduce heat and battery use.",
             detail = function()
                if not M.can_cap then return "as the display asks" end
                return CAPS[M.cap][2]
            end, choice = function()
                if not M.can_cap then return nil end
                return M.cap, #CAPS
            end, act = "cap"},
            {label = "fullscreen", detail = "fill the screen",
             help = "Hide the browser controls while you play.",
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
                               detail = "one tap", act = "install",
                               help = "Launch the game without the browser around it."}
        elseif how == "share" then
            rows[#rows + 1] = {label = "add to home screen",
                               detail = "how to", act = "install",
                               help = "Launch the game without the browser around it."}
        end
        -- The two pages that used to be tabs of their own. Both are about the
        -- machine rather than about a match, which is what this page is for:
        -- the controls board is where the keys are set, and `about` is three
        -- lines that never deserved a destination.
        rows[#rows + 1] = {label = "controls", sect = "the machine",
                           detail = "keys and pads", go = "controls",
                           help = "Review or change every input."}
        rows[#rows + 1] = {label = "about", detail = "this build",
                           go = "about",
                           help = "Build, connection, and device details."}
        -- And the two preferences that used to sit under the roster: the
        -- wake and which key throws which charge. Both are about a look and
        -- a keyboard rather than about how a ship fights, so neither went to
        -- the panel that replaced the ship page. See decision 100.
        for _, r in ipairs(flair_rows()) do rows[#rows + 1] = r end
        return rows
    end},

    -- The controls used to be a line of text across the bottom of the screen
    -- in every frame of every game. They are read once and never again, and
    -- on a phone they were laid over the thumbs, naming keys the device does
    -- not have while the controls it does have sat unexplained. A thing you
    -- consult belongs somewhere you go to consult it.
    -- One row per control, with the key it is on at the end of it, drawn by
    -- the same list every other page here is drawn by. The layout itself is
    -- decision 33: the original's keys where the browser permits them, the
    -- nearest safe key where it does not.
    --
    -- Built from arena/controls.lua rather than written out here, which is
    -- what these rows used to be. Two hand-kept lists of the same facts drift,
    -- and these did: they were describing a game with no map on the dial and
    -- nobody riding anybody, months after both landed. A row with no `pad` is
    -- a control a thumb cannot work and is left out rather than named.
    --
    -- The page used to draw a picture of a keyboard on any window wide enough
    -- for one, with every control a chip under it three across. The menu is
    -- one column at a phone's measure now, and a board drawn across it comes
    -- out with 15-point keys, so what a phone always had is what every device
    -- gets. See .design/menu-unify.
    controls = {rows = function()
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
                rows[i] = {label = c.name, detail = c.show,
                           control = c.id, fixed = c.fixed,
                           arming = M.arming == c.id,
                           act = "bind", pick = true}
            end
        end
        if not M.touching then
            -- Last, and after every control, because it is about all of them.
            rows[#rows + 1] = {label = "reset to defaults", act = "defaults",
                               pick = true, reset = true}
        end
        return rows
    end},

    -- What this build is, rather than what the game is.
    --
    -- The page used to be six lines explaining energy and the score, which is
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
            -- How the line is behaving, as the four bars the drawer's own
            -- topbar used to carry. That topbar is gone, and the meter
            -- was the one reading on it worth keeping: the HUD warns when the
            -- line is bad enough to fly badly, and this is where a player who
            -- suspects the network goes to look. Set by the arena, because
            -- smoothing a noisy round trip into a bar count is the frame
            -- layer's job and this file knows about pages rather than packets.
            {label = "line", detail = function()
                local n = M.link_bars or 4
                if n >= 4 then return "good" end
                if n == 3 then return "fair" end
                if n == 2 then return "poor" end
                return "barely there"
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
                return directory.label_of(M.zone)
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

-- The page the stack is standing on, or nothing where the column is standing
-- on its own three stops.
--
-- An empty stack is the ordinary state here rather than a case to guard: the
-- column is the menu, and a page is what one of its stops opens over it. That
-- is the whole depth of this tree now. The drawer's own fallback, which
-- answered the tab row for a stack naming a page that had gone, went with the
-- tab row: a stop that cannot be opened is not drawn, so there is no stale
-- name for the stack to hold.
local function node()
    return NODES[M.stack[#M.stack]]
end

local function rows_of(nd)
    local r = nd.rows
    if type(r) == "function" then return r() end
    return r
end

-- The column's three stops: the way out of the seat, the machine, and which
-- side you are on.
--
-- The whole of the in-game menu, and the only place settings is reachable at
-- all. It reads as the landing's column reads because it is the same column:
-- the same stops at the same width over the same breathing key, with LEAVE
-- where the account stop stands and RESUME where PLAY NOW does. A pilot
-- learns one interface and presses it in both places.
--
-- Order is top down, the way they are drawn, and it is deliberate: LEAVE
-- farthest from the key that resumes, so the press that ends a match is the
-- one press furthest from the thumb resting on the one that ends the menu.
--
-- Nothing here needs a room to be between matches. Nothing pauses while this
-- stands: the column takes the controls and the ship goes on flying under it,
-- so a pilot reading settings can be shot for reading them. That is the same
-- bargain the drawer struck and the reason this is three stops rather than a
-- place to spend time in. See docs/design/match-game.md.
function M.stops()
    local out = {}
    -- Leaving goes one step, and which step is whichever one you are standing
    -- on. Flying, it hands the seat back and leaves you watching the same
    -- room, so the column stays up: nothing about where you are has changed,
    -- and the corner's TAKE SEAT is the way back in. Benched, there is no seat
    -- left to hand back and the step is out of the room to the stands, which
    -- costs the match and is the one that asks first.
    -- The answer is the thing being left rather than a sentence about
    -- leaving it. That is the grammar every stop in this column speaks and the
    -- landing's speak too: the label asks and the answer is a name. "To the
    -- stands" was a phrase in the slot a name goes in, and it read as one:
    -- three words of interface prose set in the face the arena reserves for
    -- data.
    if M.flying() then
        out[#out + 1] = {stop = "leave", label = "leave",
                         value = "seat", act = "leave_seat"}
    else
        out[#out + 1] = {stop = "leave", label = "leave",
                         value = "game", act = "leave"}
    end
    -- Everything about the machine rather than about a match, in one page:
    -- audio, video, the bindings, and about. It opens the way the landing's
    -- ship stop opens, as a panel climbing off its own row.
    out[#out + 1] = {stop = "settings", label = "settings", mark = "settings",
                     go = "settings"}
    -- And which side you are on. Last because it is the one stop a room can
    -- fail to offer: a zone names its sides on the roster broadcast rather
    -- than in the join, so this arrives a frame or two after the rest of the
    -- column and appearing at the foot shuffles nothing above it.
    if #net.teams > 0 then
        out[#out + 1] = {stop = "side", label = "side",
                         value = net.my_team_name(), named = true,
                         go = "side"}
    end
    return out
end

-- Which stop's page is open, or nil for the bare column.
function M.stop_open()
    return M.stack[1]
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
        label = r.label, detail = d, note = r.note, help = r.help,
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
        choice = ci, choices = cn, bar = r.bar, ship = r.ship,
        -- The label a group of rows sits under, on the first row of it,
        -- with the count beside it and the sentence under it where the
        -- section has one.
        sect = r.sect, sect_note = r.sect_note, sect_line = r.sect_line,
        who = r.value, state = r.state, dim = r.dim,
        group = r.group, short = r.short, tint_col = r.tint_col,
        -- What a ship row carries beyond the hull to draw: where it stands on
        -- the five flight rows against the rest of the roster, what it flies
        -- with, and whether it has a bomb rack at all.
        bars = r.bars, carries = r.carries, rack = r.rack,
        icon = r.icon,
        -- A row the page draws as a button, and which mark goes on it.
        button = r.button,
        -- What the controls page needs from a row: which control it stands
        -- for, whether that one is nobody's to move, whether it is the one
        -- waiting for a key, and whether it is the row that puts everything
        -- back. The color band and the chord went with the drawn keyboard,
        -- which was the only thing that read either.
        control = r.control, fixed = r.fixed,
        arming = r.arming, reset = r.reset,
        pick = (r.go or r.act) ~= nil, act = r.act,
        mark = r.mark and r.mark() or false,
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
        -- Nothing to say. Everything that lands here is a press that changed
        -- nothing, and saying "that is already where it is" to somebody who
        -- pressed the key it is already on is noise. A control that is not
        -- ours to move used to be answered here too; it is refused a step
        -- earlier now, where the row declines to start asking at all, so an
        -- id that reaches this line is never a fixed one.
        M.foot = nil
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

-- Which level is on screen, so the arena knows what is being read.
function M.at()
    return M.stack[#M.stack]
end

-- Raise or lower the column.
--
-- It comes up on its bare stops every time, whatever was open last. A menu
-- that reopens on the page you left is a menu that reopens on the controls
-- board a fortnight later, and the three stops are one press from anywhere
-- anyway.
function M.toggle()
    if M.open then
        M.close()
    else
        M.stack = {}
        M.open = true
        M.note = nil
    end
    return M.open
end

-- Open one of the column's stops, by name. Pressing the one already open
-- shuts it, which is what the caret on the stop draws and what the landing's
-- own stops do.
function M.open_stop(name)
    if M.stack[1] == name then
        M.stack = {}
    else
        M.stack = {name}
    end
    M.arming = nil
    return M.stack[1]
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
        M.confirm("Log off " .. M.name .. "?",
                  {{label = "log off", act = "do_logout"}, {label = "stay"}})
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
    else
        return act
    end
    return nil
end

-- The one act on the account list that throws something away, and the card
-- that stands in front of it.
--
-- A call sign is the only name anybody has here, it is the name on the
-- scoreboard of every game this pilot has flown, and the control that showed
-- it used to replace it on the press with nothing said. Mid-game the roll is
-- also a respawn, because a new name is a new pilot and the seat is rejoined
-- to wear it. Said on the card rather than discovered.
--
-- One way in now, the landing's account list, and the card it raises stands
-- over the landing with no panel behind it. "reroll" therefore means "ask"
-- from a control and "roll" from the card's own answer, which is what `settle`
-- does with it.
local function ask_reroll()
    local head = "your call sign is " .. M.name
    if not M.home then
        head = head .. ". A new one respawns your ship"
    end
    M.confirm(head, {{label = "roll", act = "reroll"}, {label = "keep"}})
end

-- One of those acts, run by name, for a caller with no row to press.
--
-- The landing's account list is that caller: its rows are `M.account_rows`
-- and they carry the same act names the pilot page's rows carried, so
-- pressing one has to land exactly where pressing a row did, guard and all.
--
-- Answers what the caller must apply, the same as a row press: nil when the
-- act settled here, which every account act but none of the arena's does.
function M.activate_act(act)
    if act == "reroll" then
        ask_reroll()
        return nil
    end
    return settle(act)
end

-- Raise a question. `keys` is the answers in the order they are drawn, each a
-- label and the action answering it returns, and the last of them is the one
-- that changes nothing: it is what escape gives, so a question can always be
-- got out of by the key that gets out of anything. On a plain question the
-- cursor starts there too; a card with fields starts on its first key, since
-- the whole point of raising one is to fill it in and send it.
function M.confirm(head, keys)
    M.ask = {head = head, keys = keys, sel = #keys}
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
    local head = account.claimed and "Choose a new password." or "Sign up."
    M.ask = {head = head,
             -- The one line the old page said in three places, kept where
             -- the act is: what signing up buys.
             note = not account.claimed
                 and "keep your points and log in on other devices" or nil,
             keys = {{label = account.claimed and "change" or "sign up",
                      act = "do_claim"}, {label = "cancel"}},
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

-- Open the column at a particular level, which is what a failed connection
-- wants: the reason belongs next to the thing that would fix it.
function M.show(...)
    M.stack = {}
    for _, id in ipairs({...}) do M.stack[#M.stack + 1] = id end
    M.open = true
    M.ask = nil
end

-- Closing forgets where you were. A menu that reopens three levels down is a
-- menu that answers a different question than the one you asked it: the first
-- version of this kept the stack, and pressing escape then down then enter,
-- which had meant a play row a moment earlier, silently changed hull instead.
function M.close()
    -- Always. There was a rule here refusing to close a menu with nothing
    -- behind it, because closing onto an empty starfield with no way back is
    -- a button that breaks the game. What is behind it now is either the
    -- stands or the waiting screen, and both of those carry MENU, so there is
    -- no state this can strand anybody in.
    M.open = false
    M.stack = {}
    -- Nothing is waiting on a room any more: the panel a landing would have
    -- taken away is already gone.
    M.await = nil
    -- A question belongs to the panel it was asked in. Left standing, it would
    -- be waiting on the next thing to open the menu, which is a player pressing
    -- escape mid-fight and being asked something they have forgotten.
    M.ask = nil
    -- The same rule for a control waiting on a key, and a harder one: it holds
    -- the whole keyboard while it is up, so left standing behind a shut menu
    -- it would swallow the next press of anything.
    M.arming = nil
    M.foot = nil
    return true
end


-- Whether this guest has anything a lost account would cost, which is a rated
-- game flown. That is what arms the banner and the rail dot; before there is
-- anything to lose they stay away, because a warning over an empty account is
-- nagging.
--
-- An upgrade bought past the baseline was the other half of this, and there
-- are no upgrades. A rating is the only durable thing a pilot has now, so the
-- question is simply whether they have started earning one.
--
-- Up here rather than beside the view that reads it, because `M.tick` reads
-- it too: the career this asks about is fetched once a session, which is a
-- session too late for the guest who flies their first game in it.
local function guest_stakes()
    if account.base == "" or account.claimed then return false end
    return ((account.career or {}).games or 0) > 0
end

-- And the same question from outside, for the landing's account stop, where
-- the warning is a dot on the stop it is about. The drawer drew it as a band
-- across the foot of its column, which went with the drawer.
function M.guest_stakes()
    return guest_stakes()
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
    -- A stop the column no longer carries is a page you are no longer in. The
    -- sides are the one that comes and goes: a room names them on the roster
    -- broadcast, and a disconnect takes them away under a pilot standing in
    -- the list.
    if M.stack[1] then
        local held = false
        for _, s in ipairs(M.stops()) do
            if (s.go or s.stop) == M.stack[1] then held = true break end
        end
        if not held then M.stack = {} end
    end
    if M.at() ~= "controls" then M.foot = nil end
    -- The career, while a guest still has nothing a sweep would cost
    -- them. It was also re-asked whenever the pilot page came up, and that
    -- page is gone: the warning below is the only reader left, and it reads
    -- from every tab rather than from a page you have to visit.
    --
    -- One request per session was enough while the pilot page was the only
    -- reader, since that page asked again on arrival; a guest's first rated
    -- game is filed long after the session woke. So the copy this client held
    -- said no games for the whole of the session the first game was flown in,
    -- and the warning that is supposed to arrive the moment there is
    -- something to lose arrived a session late, which for a player who never
    -- comes back is never.
    --
    -- It stops as soon as it has an answer, and it never starts for a claimed
    -- pilot or for a guest who has already bought a rung.
    career_due = career_due - (dt or 0)
    if career_due <= 0 then
        career_due = CAREER_EVERY
        if account.base ~= "" and not account.claimed and not guest_stakes()
        then
            account.refresh_career()
        end
    end
end

-- What the drawing code needs, and nothing about how it is drawn. Values are
-- resolved here so ui.lua never calls back into this file mid-frame.
--
-- The whole payload is the column: three stops, and the rows of whichever one
-- is open over them. There was a rail, a stage, a topbar, a head and a preview
-- of the page the rail cursor pointed at, which was five answers to "where am
-- I" on a panel with four pages behind it. A stop that is lit and a panel
-- climbing off it is one answer, and it is the one the landing already gives.
function M.view()
    local out = {open = M.open, at = M.at(), ask = M.ask, note = M.note,
                 class = M.class, arming = M.arming ~= nil, foot = M.foot,
                 -- Who is reading this, for the panel's own foot. It rode the
                 -- drawer's topbar, which was the one line on screen saying
                 -- who you are signed in as; out here the landing's account
                 -- stop says it, so this is only for the pages that have no
                 -- other way to name the account they are about.
                 pilot = {name = M.name},
                 stops = {}, rows = {}}
    for i, s in ipairs(M.stops()) do
        out.stops[i] = {stop = s.stop, label = s.label, value = s.value,
                        mark = s.mark, named = s.named,
                        -- Lit while its own page is open, which is what the
                        -- caret on it turns over.
                        open = M.stack[1] == s.stop}
    end
    local nd = node()
    if nd then
        for i, r in ipairs(rows_of(nd)) do out.rows[i] = view_row(r, i) end
        -- How deep in the settings page a hand has walked, so the panel can
        -- draw the way back. One level is the stop's own page; two is a page
        -- that page opened.
        out.depth = #M.stack
        out.page = M.at()
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

-- Is there anywhere to be on that page yet?
--
-- Whatever comes over the wire is not there until it lands, and stepping into
-- a page of none takes the arrows off the tab row and puts the cursor nowhere:
-- down did nothing visible, and the way back was a key nobody had a reason to
-- press. The stage already previews the page from the tab above it, so
-- refusing the step hides nothing, and the press starts working the moment the
-- rows arrive.
--
-- The games list was what this guarded, and picking a game is the landing's
-- now. What is left that can stand empty is the sides, and that one hides its
-- own stop until the room has sent some, so the two agree within a frame and
-- this is the belt to that pair of braces rather than the only thing holding
-- them up. It stays because the next page over the wire will need it, and
-- because a rail stop and its page are two places to remember one rule.
--
local function enterable(id)
    local nd = NODES[id]
    if not nd then return false end
    -- A page whose whole content is a reading has nothing to stand on and is
    -- still worth entering.
    if nd.reading then return true end
    return #rows_of(nd) > 0
end

-- Press a row, or nudge it. Returns an action for the arena, or nil.
--
-- `by` is -1 or 1 from left and right on a row that carries a range, and nil
-- from enter. A row with a range is a value rather than a destination, so the
-- arrows set it and enter cycles it, which is what those keys mean everywhere
-- else in the game.
--
-- Takes the row rather than reading a cursor. The cursor is ui.lua's now,
-- standing on a box that was actually drawn, and a press arrives here already
-- knowing which row it landed on.
local function activate_row(r, by)
    if not r then return nil end
    if r.go then
        if not enterable(r.go) then return nil end
        M.stack[#M.stack + 1] = r.go
        M.note = nil
        return nil
    end
    if not r.act then return nil end

    -- The ones this file can settle itself.
    --
    -- Enter on a ship row picks that hull, and that is the whole of the
    -- page. Nothing on it spends anything: what a hull carries is the hull's,
    -- so there is no arrow that adds a point and no key that buys one.
    if r.act == "swap_charges" then
        M.swap_charges()
        return nil
    elseif r.act == "hull" then
        -- A row on the roster. Enter asks for that ship; the arrows walk the
        -- list, which the navigation above already does, so there is nothing
        -- for a direction to mean here.
        if by then return nil end
        if r.value == nil then return "spectate" end
        M.pending = r.value
        return "ship"
    elseif r.act == "wake" then
        -- One step round the wakes, whichever way the press points; enter
        -- steps forward, so a hand on enter alone can still reach all of
        -- them. Saved at once: a cosmetic that lasted one session would
        -- read as a setting that failed to take.
        M.wake = (M.wake + (by or 1)) % #M.WAKES
        M.save_identity()
        return nil
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
    elseif r.act == "leave" then
        local place = M.zone ~= "" and directory.label_of(M.zone)
            or "this game"
        M.confirm("leave " .. place .. "?",
                  {{label = "leave", act = "leave"}, {label = "stay"}})
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
        ask_reroll()
        return nil
    elseif r.act == "leave_seat" then
        -- The seat handed back, the room kept. Nothing else about this
        -- client moves, so the panel stays where it is: what changed is on
        -- the glass behind it.
        return "leave_seat"
    end
    return settle(r.act, nil, by)
end

-- keys: {left, right, up, down, go, back, rub} as booleans, already
-- edge-detected by the arena script: a tap can go down and up inside one frame
-- and never appear in the key state that flight reads.
--
-- Returns an action name or nil, and whether anything moved, so the caller can
-- make a noise about it.
--
-- A question is the whole of what this reads now. The column is walked by the
-- boxes it published, in ui.lua, the way the landing has always been walked:
-- one cursor over what is actually on the screen, rather than a second tree of
-- rows kept in step with the drawing by hand. What went with the drawer was a
-- rail axis, a head row, a grid branch no page set, and a call to `rub_new`
-- that has never existed: backspace with the panel up and nothing asking
-- raised `attempt to call a nil value` in the arena's input handler.
function M.step(keys)
    if not M.ask then return nil, false end
    local n = #M.ask.keys
    -- Backspace belongs to the fields when there are fields.
    if keys.rub and M.rub_field() then return nil, true end
    -- Escape is the last answer, which is the one that changes nothing.
    if keys.back then return answer(n) end
    -- On a card with lines to fill in, up and down walk the lines and left and
    -- right walk the answers; enter sends. On a plain question all four walk
    -- the answers, so arrows never do nothing.
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

-- One of the column's stops, pressed: it opens its page, or acts where it has
-- no page to open.
function M.press_stop(name)
    for _, s in ipairs(M.stops()) do
        if s.stop == name then
            if s.go then
                M.open_stop(s.go)
                return nil, true
            end
            return activate_row({act = s.act}), true
        end
    end
    return nil, false
end

-- One row of an open page, pressed.
function M.press_row(i)
    local nd = node()
    if not nd then return nil, false end
    local r = rows_of(nd)[i]
    if not r then return nil, false end
    if r.go then
        M.stack[#M.stack + 1] = r.go
        return nil, true
    end
    if not r.act then return nil, false end
    return activate_row(r), true
end

-- And one stepped: the two triangles either side of a value, or left and right
-- with the cursor standing on it. A row with no range to walk answers nothing,
-- so a press that means nothing here makes no noise.
function M.step_row(i, dir)
    local nd = node()
    if not nd then return nil, false end
    local r = rows_of(nd)[i]
    if not r or not r.choice or not r.act then return nil, false end
    return activate_row(r, dir), true
end

-- Out of the page a stop opened, one level. At the first level that is the
-- stop shutting, which leaves the bare column standing.
function M.page_back()
    if #M.stack == 0 then return false end
    table.remove(M.stack)
    M.arming = nil
    return true
end

function M.click_wake(dir)
    M.wake = (M.wake + (dir or 1)) % #M.WAKES
    M.save_identity()
    return nil, true
end

-- Is there still a row there?
--
-- A press is tested against hit boxes the previous frame published, and some
-- of these lists are rebuilt underneath them: a side can leave the roster
-- between the drawing and the press. The cursor itself is ui.lua's, standing
-- on a box that was actually drawn; this is the one question about a row that
-- only the file holding the rows can answer.
function M.has_row(index)
    local nd = node()
    if not nd or not index then return false end
    return rows_of(nd)[index] ~= nil
end

-- Whether there is a level to come back out of, which is what a swipe asks
-- before it takes the gesture off the page under it.
function M.can_back()
    return M.open and #M.stack > 0
end

return M
