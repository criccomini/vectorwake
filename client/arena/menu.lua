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
-- frame, and declared here because `M.in_zone` reads it before the first one.
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
-- somewhere else. See `M.want_zone` and `M.arrived`.
M.await = nil
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

-- Whether this client is in a given game at all, by any of the three ways
-- there are to be in one: flying it, benched in it, or watching it from the
-- stands. What it is not is "the zone I last asked for": a name is remembered
-- across a drop, and a press that answered off the remembered one would put
-- the panel away over a starfield.
function M.in_zone(zone)
    if zone == nil or zone == "" or M.zone ~= zone then return false end
    if M.home then return M.scenery end
    return true
end

-- A press on a game: be in it.
--
-- Answered here where the client already is, since there is nothing to wait
-- for; recorded and left to the stands otherwise. Returns the act the arena
-- runs, which is nil where the answer was "you are already there".
function M.want_zone(zone)
    if zone == nil or zone == "" then return nil end
    if M.in_zone(zone) then
        -- Already there, whether flying it or watching it. The panel is the
        -- only thing between this player and that room, so the press takes
        -- the panel away and nothing else: a press meaning "be here" on the
        -- room you are in must not cost you the seat you are in it with.
        M.await = nil
        M.close()
        return nil
    end
    M.await = zone
    M.note = nil
    return "want_zone"
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
-- A ship is preconstructed: its flight row, its gun and bomb, and the profile
-- it wears all belong to the hull and are set by the zone. So the page that
-- used to build one is a page that picks one.
--
-- What stood here was the kit: twenty-three slots over a flat slot space, a
-- thirty point budget, an arena ceiling and an account's entitlements to
-- check them against, a shelf to buy the rungs from, a wallet to buy them
-- with, and named builds to save the result under. All of it is gone. What a
-- pilot chooses is a hull, and the hull is the ship.
--
-- The slot space itself stays, because that is still how the core writes down
-- what a ship carries. It is read here rather than written: the numbers
-- belong to the class now, and this file turns them into words.

-- What a hull flies with, over the flat slot space, or nil before the core
-- has a settings table to read it from.
local function class_kit(cls)
    local core = _G.sim
    return core and core.class_kit and core.class_kit(cls) or nil
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

-- What a hull carries, as short words, in the order a reader meets them:
-- the gun's add-ons, then the bomb's, then the rack.
--
-- Only what it actually holds. A list naming every slot with a zero beside
-- it is the old shelf again, and there is no shelf.
local function carried(cls)
    local kit = class_kit(cls)
    if not kit then return {} end
    local up = simn("UP_COUNT", 5)
    local trig = simn("TRIG_COUNT", 2)
    local mods = simn("MOD_COUNT", 6)
    local mod0 = simn("SLOT_MOD0", up + trig)
    local ch0 = simn("SLOT_CHARGE0", up + trig + trig * mods)
    local out = {}
    for t = 0, trig - 1 do
        for m = 0, mods - 1 do
            local n = kit[mod0 + t * mods + m + 1] or 0
            if n > 0 then
                local mod = pal.MODS[m + 1]
                local word = (t == 0 and "gun " or "bomb ")
                    .. (mod and mod.name or ("add-on " .. m))
                -- Spray is a count of rounds and reads as one. Everything
                -- else is a rung of something and reads as a depth.
                if m == simn("MOD_MULTI", 0) then
                    word = word .. " " .. (n + 1)
                elseif n > 1 then
                    word = word .. " " .. n
                end
                out[#out + 1] = word
            end
        end
    end
    for k = 0, simn("MAX_CHARGES", 4) - 1 do
        local n = kit[ch0 + k + 1] or 0
        if n > 0 then
            local c = pal.CHARGES[k + 1]
            out[#out + 1] = (c and c.name or ("charge " .. k)) .. " " .. n
        end
    end
    return out
end

-- Whether this hull has a bomb rack at all. One in the roster does not, and a
-- page that said nothing about it would read as a page that forgot.
local function has_rack(cls)
    local core = _G.sim
    if not (core and core.has_trigger) then return true end
    return core.has_trigger(cls, simn("TRIG_BOMB", 1)) ~= false
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




-- The roster, one row a hull, and the row is the ship.
--
-- Every hull the game has, in the core's own order, with the one being flown
-- lit. Pressing a row picks that ship, which is the whole of what this page
-- does: a hull carries its own flight row, its own gun and bomb and its own
-- profile, so choosing it is choosing all of them at once.
--
-- The row is also the reading. Its flight sits under its name as five bars
-- against the rest of the roster, and what it carries is spelled out beside
-- them, so seven ships are one page rather than seven pages. See
-- docs/design/ships.md.
local function ship_rows()
    local rows = {}
    for i, h in ipairs(HULLS) do
        local cls = i - 1
        rows[#rows + 1] = {
            label = h[1], verbatim = true, group = "ships", sect = "ships",
            -- The silhouette in a word, and the shape it presents in a
            -- sentence under it. Both are about the one thing a player can
            -- see from the cockpit.
            detail = h[2], note = h[3],
            act = "hull", value = cls,
            -- Lit where it is the ship you fly, the way one field lights a
            -- row everywhere else in this menu.
            choice = function()
                return (not M.spectating() and M.class == cls) and 1 or 0, 1
            end,
            -- What the drawing needs: the hull to draw, where it sits on the
            -- five flight rows, and what it carries.
            ship = true, hull = cls,
            bars = flight_bars(cls), carries = carried(cls),
            rack = has_rack(cls),
        }
    end
    -- Sitting out is the eighth thing you can be flying, so it is the eighth
    -- row rather than a control somewhere else. Picking a hull is already how
    -- a pilot says what they want to be, and "nothing, I am watching" is an
    -- answer to that question.
    --
    -- On the home screen too, where this page is what you will arrive as
    -- rather than what you are. Arriving to watch is a thing the wire has
    -- always been able to say, so picking it here carries into the join
    -- rather than waiting for a game to exist.
    rows[#rows + 1] = {
        label = "spectate", verbatim = true, group = "ships", sect = "ships",
        detail = "no hull", note = "watch the room from nobody's cockpit",
        act = "hull",
        choice = function() return M.spectating() and 1 or 0, 1 end,
        -- The helmet rather than a ship: the row is about the pilot rather
        -- than about anything they are flying.
        ship = true, figure = "pilot",
    }
    -- Flair: what the ship looks like, apart from what it does. A wake is the
    -- one thing on this page that is still a pilot's own choice, which is why
    -- it keeps a section of its own under the roster.
    rows[#rows + 1] = {
        label = "wake", verbatim = true, group = "flair", sect = "flair",
        detail = M.WAKES[M.wake + 1],
        act = "wake",
        choice = function() return M.wake + 1, #M.WAKES end,
    }
    -- And which of the two charge keys throws which kind, where the ship you
    -- fly carries two. A preference about a keyboard rather than a fact about
    -- a ship, so it sits with the wake rather than with the roster, and it is
    -- absent on a hull that carries one kind or none, where there is nothing
    -- to trade.
    --
    -- It was a box on the charge's own row while the page was a kit being
    -- built. There are no charge rows now, and this is the one thing that
    -- page carried which is still a pilot's to decide.
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
            label = "charge keys", verbatim = true, group = "flair",
            sect = "flair", detail = names[1] .. " first",
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
    -- The tab row, and the whole of the front end's shape.
    --
    -- Three stops at home: ship, pilot, settings. In a room: the side you are
    -- on, the ship in the window where a hull is not locked, the way out, and
    -- settings. The row keeps the same place and chrome in both contexts.
    --
    -- No games on it, and no games page behind it. Picking one is what the
    -- landing's zone stop is for, and the drawer's own copy of that list put
    -- two lists of the same games on the same screen at home, sitting one
    -- over the other. See decision 98.
    --
    -- What decides which stops you get is whether you are in a hull, not
    -- whether you are in a zone. The question used to be `M.home`, which was
    -- the same answer while the front end was a place of its own. It is the
    -- stands now, and a pilot who sat out mid-match is in the stands too:
    -- same empty cockpit, same time to read.
    --
    -- Nothing you cannot act on right now is on that row while you are
    -- flying. A three minute match is short enough that a menu deep enough to
    -- read a roster in costs a real fraction of it, and nothing pauses: you
    -- can be shot while you read, which is why the roster is on it only in
    -- the window between matches. See docs/design/match-game.md.
    root = {rows = function()
        local rows = {}
        -- Which side you are on, and the page that crosses to the other one.
        -- A side is a thing a room has, so the stop appears with the room
        -- rather than standing at home saying nothing. It was the last row of
        -- the games page, which is a page that no longer exists.
        if not M.home and #net.teams > 0 then
            rows[#rows + 1] = {label = "side", icon = "team",
                               detail = function()
                                   return net.my_team_name()
                               end, go = "teams"}
        end
        -- One choice made in one place. It used to be two, a hull and then
        -- the points spent inside it; a hull is the whole ship now, so there
        -- is one thing to pick and one page to pick it on.
        --
        -- Off the row while a match is being flown. Between matches the hull
        -- is not locked, and that is the one window a pilot has to change it
        -- without leaving the room; it is gone again the moment the next
        -- whistle goes, which is the rule rather than a hurry we invented: a
        -- ship is settled before a match, never during one.
        if not M.flying() or M.between() then
            rows[#rows + 1] = {label = "ship", icon = "ship",
                               detail = function()
                                   if M.spectating() then
                                       return "spectating"
                                   end
                                   return HULLS[M.class + 1][1]
                               end, go = "hangar"}
        end
        -- The way back out of a room. At home there is nothing to leave, and
        -- nothing stands in this slot: the account used to, and the landing's
        -- account stop is where that lives now. See decision 99.
        --
        -- Leaving goes one step, and which step is whichever one you are
        -- standing on. Flying, it hands the seat back and leaves you watching
        -- the same room, so the panel stays up: nothing about where you are
        -- has changed, and the corner's TAKE SEAT is the way back in. Benched,
        -- there is no seat left to hand back and the step is out of the room
        -- to the stands, which costs the match and is the one that asks first.
        --
        -- It was a button on the row of the game you were flying, on the
        -- argument that a stop on this row put the way out of a game beside
        -- the way to the sound settings. That argument was about a games list
        -- to hang it on, and there is none: the way out of a room belongs on
        -- the row that is what the drawer has left.
        if not M.home then
            if M.flying() then
                rows[#rows + 1] = {label = "leave", icon = "leave",
                                   detail = "stop flying, keep watching",
                                   act = "leave_seat"}
            else
                rows[#rows + 1] = {label = "leave", icon = "leave",
                                   detail = "back to the stands", act = "leave"}
            end
        end
        -- Everything about the machine rather than about a match, in one
        -- column: audio, video, the bindings, and about. Help folded into it
        -- because the controls board and the rebinding screen were always the
        -- same list read two ways.
        --
        -- Last, which is where it sits on every row and where a phone's own
        -- tab bars put it when they carry one at all. It is the least pressed
        -- stop here and the only one that is not part of the game, so it takes
        -- the end of the row and the stop that varies with where you are
        -- standing takes the slot before it. See decision 83.
        rows[#rows + 1] = {label = "settings", icon = "settings",
                           go = "settings"}
        return rows
    end},

    -- The roster: one row a hull, and the row is the ship.
    --
    -- Four pages stood behind this one and all four were about a kit. The
    -- shelf that sold rungs, the library of saved builds, the field that
    -- named a new one, and the reading that explained what thirty points
    -- were. None of them survived: a hull is a whole ship, so the row says
    -- the whole of it and there is nothing left to stand behind the page.
    hangar = {rows = ship_rows},

    teams = {rows = team_rows},

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

-- The controls on the drawer's own top line, in the order the arrows meet
-- them left to right: the x that shuts the panel, and the call sign that says
-- who you are signed in as.
--
-- A row of its own, rather than the far end of the rail. They were stops on
-- the rail, reached by pressing right off the last tab, which is a row along
-- the bottom of the column reaching a button at the top of it: the cursor
-- crossed the whole height of the panel sideways and the row wrapped through
-- a control nobody could see it arrive at. They are drawn as a head over the
-- page, so they are a head over the page here as well, and up off the first
-- row of a page is how a hand reaches them.
--
-- The x is the whole of this row now. The call sign at the other end of it
-- was a stop as well, the second door onto a pilot page that no longer
-- exists; it stays as a label, because it is still the one thing on screen
-- saying who you are signed in as, and a label is not a stop.
--
-- The list is here rather than in the drawing because the arrows walk it, and
-- a row a hand can walk has to be a list somewhere. ui.lua draws the x at one
-- end of that line and the name at the other; both read this.
local function head_stops()
    return {"close"}
end

-- Where a page's cursor opens when nobody has moved it. The first row
-- everywhere, except the tab row in a room, where it is the last stop.
--
-- That last stop is settings on every row by decision 83, and it is where the
-- panel opens over a game: the safe act during a fight, and the one that keeps
-- `leave` off the opening cursor now that the two are neighbours.
--
-- Answered as a rule rather than written into `M.sel` when the panel opens,
-- because the row can grow after that. `side` appears at the head of it when a
-- room names its sides, and a room names them on the roster broadcast rather
-- than in the join, so it can land a frame or two after the drawer went up.
-- Every stop shuffles along one under a stored number, and the one a cursor
-- resting on the end would shuffle onto is `leave`: escape then enter would
-- have handed back the seat.
local function opens_at(id, n)
    if id == "root" and not M.home then return n end
    return 1
end

-- Which page's rows are on screen. One level in that is the page you are
-- inside; at the root it is whichever tab the cursor is resting on, because
-- the stage there is a preview of what that tab holds.
function M.showing()
    if #M.stack > 1 then return M.at() end
    local top = rows_of(NODES.root)
    local r = top[M.sel.root or opens_at("root", #top)]
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

-- The next row the arrows stop on, walking one step in `dir` and wrapping.
--
-- A row that is neither a destination nor a value is a readout, and the cursor
-- has no business standing on one: left does nothing from it, right does
-- nothing to it, and on the ship page left is the way out, so walking down
-- from the ship onto a readout and pressing left shut the page. Skipped
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

-- Where a walk into a page from the rail lands, coming down: the first row of
-- the list.
--
-- The page's own head is not it. A page that carries one draws it over the
-- list rather than in it, so a hand coming into the page is coming into the
-- list.
local function first_stop(rows)
    for i, r in ipairs(rows) do
        if (r.go or r.act) and r.group ~= "band" then return i end
    end
    return next_stop(rows, #rows, 1)
end

local function row_index(rows)
    local id = M.stack[#M.stack]
    local n = #rows
    local i = M.sel[id]
    -- Left unwritten while it is still the default, so the rule above goes on
    -- answering as the row changes shape. Moving the cursor writes it, and
    -- from then on it is a number like any other page's.
    if i == nil then return opens_at(id, n) end
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
        -- Always the tab row. It opened on the games at home, which was the
        -- one page worth landing a player on and is gone: the landing behind
        -- this panel is where a game is picked now, so the drawer opens on
        -- the row and the first stop is the ship.
        M.stack = {"root"}
        -- And with no cursor of its own, so `opens_at` goes on answering
        -- where it rests: the ship at home, settings over a game.
        M.sel.root = nil
        M.open = true
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
-- Both ways in pass through here: a row of the drawer and a row of the
-- landing's list. "reroll" therefore means "ask" from a control and "roll"
-- from the card's own answer, which is what `settle` does with it.
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

-- Open the menu at a particular level, which is what a failed connection
-- wants: the reason belongs next to the thing that would fix it.
function M.show(...)
    M.stack = {"root"}
    for _, id in ipairs({...}) do M.stack[#M.stack + 1] = id end
    M.open = true
    M.hover = nil
    M.rail_hover = nil
    M.head_sel = nil
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
    M.stack = {"root"}
    -- Nothing is waiting on a room any more: the panel a landing would have
    -- taken away is already gone.
    M.await = nil
    M.hover = nil
    M.rail_hover = nil
    M.head_sel = nil
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
        M.head_sel = nil
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
-- It shuts the panel and puts you back in what is behind it, whatever level
-- you are on. One press put the menu up, so one press has to take it down;
-- walking back out a level at a time made leaving cost three presses where it
-- used to cost two. Left and the chevron are what walk back through the tree,
-- which is a different question with its own keys.
--
-- This used to be two behaviors that nobody chose between: it tried to close,
-- and the front end's refusal to close turned it into `back` there. Both
-- halves of that are gone, since everything is over a room now, so the one
-- meaning is written here rather than falling out of a refusal.
local function escape()
    M.close()
    return nil, true
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

-- And the same question from outside, for the landing's account stop: the
-- warning the drawer draws as a band is a dot out there, on the stop the
-- band would be pointing at.
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
            -- And off the head, which stands over a page that is no longer
            -- there: the cursor belongs to the rail again.
            M.head_sel = nil
        end
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

-- Which of the head's controls the arrows are standing on, by name, and
-- nobody while they are anywhere else. It is a cursor rather than a "you are
-- here" mark: the rail keeps that one, and it says which page the panel is
-- inside whatever line the arrows happen to be on.
local function head_lit()
    return M.head_sel and head_stops()[M.head_sel] or nil
end

-- One of them, pressed. The x shuts the panel, which is what a cross means
-- everywhere, and it is the only thing on this row that takes a press.
local function press_head(which)
    if which == "close" then return M.click_close() end
    return nil, false
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
                 -- The one line a page gets when its rows cannot say what it
                 -- is. Nearly every page here goes without: a list of games
                 -- and a roster of ships explain themselves by being read.
                 lede = nd.lede and nd.lede() or nil,
                 -- Who is reading this, which the topbar carries at the far
                 -- end of the tab row. It is the same slot the score and the
                 -- clock take in a match: the right-hand end of that row
                 -- always answers "how am I doing in the thing I am in". It
                 -- carried a wallet beside the name until there was nothing
                 -- anywhere in the game to spend.
                 pilot = {name = M.name},
                 -- Which of the head's controls the arrows are standing on,
                 -- by name rather than by number: the drawing puts the x at
                 -- one end of that line and the name at the other, and a
                 -- number would have to mean the same thing in both.
                 head_sel = head_lit(),
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
                 note = M.note, closable = true,
                 -- Which page this is, by name. The drawing keeps a scroll
                 -- position and has to know when it is looking at something
                 -- else: carried across, opening the hangar from the bottom
                 -- of the ship page would open it halfway down.
                 at = M.at(),
                 -- Whether there is a game behind the panel, which is what
                 -- decides where the block sits: clear of the corner stack
                 -- over an arena, centered over the starfield. Not whether you
                 -- are at the top of the menu. It used to say both at once,
                 -- and so the whole block moved every time you went a level
                 -- in: on a phone held sideways the rail slid 124 points out
                 -- from under the thumb that had just tapped it, and the next
                 -- tap hit nothing.
                 home = M.home,
                 -- Whether a room is playing behind this menu with no seat of
                 -- this client's in it: the stands. It is what says the panel
                 -- has something behind it to be closed onto.
                 scenery = M.scenery or false,
                 -- Who is in that room, for the column beside the page: the
                 -- same roster the scoreboard reads, and the watched side the
                 -- glass is already colored from.
                 arena = M.scenery and {
                     pilots = M.live_pilots, watchers = M.live_watchers,
                     side = M.live_side, names = M.live_sides,
                 } or nil,
                 -- Whether a control is waiting for a key, which the controls
                 -- page reads to say so on the row that asked.
                 arming = M.arming ~= nil,
                 foot = M.foot,
                 rows = {}}
    for i, r in ipairs(rows) do
        out.rows[i] = view_row(r, i)
    end
    -- The roster is a page rather than a list of rows: each row is a whole
    -- ship, with its flight against the rest of the roster and what it
    -- carries drawn under its name, so there is nothing behind it to open.
    --
    -- `M.showing()` rather than `M.at()`, which is the fix for a page that
    -- looked like two different pages depending on how you got to it: at the
    -- root the stage is a preview of the tab under the cursor, and this reads
    -- the page you are standing in, so resting on Ship showed a column of
    -- names and entering it showed the roster. A preview is the page.
    if M.showing() == "hangar" then out.ships = true end
    -- No roster under the games. The room the menu stands over used to draw
    -- itself here, first as a column beside the list and then under it, on the
    -- argument that a player choosing where to go wants to know who is where.
    -- What it actually did was put a second scoreboard on the one page that is
    -- about leaving for somewhere else, and the room behind the panel is on
    -- screen the moment the panel goes.
    -- The destinations, always, whatever level the stack is at: the interface
    -- draws them as a rail of icons and the rail is the one thing on screen
    -- that does not move. Which of them you are inside is `rail_sel`, and at
    -- the root that is simply the row the cursor is on.
    --
    -- Which one a pointer is resting on goes with them, at every level. At
    -- the root it is the cursor and says nothing new; one level in it is the
    -- only thing on screen that says what a click would land on, which is the
    -- job it does for the stage on the home screen.
    -- The guest warning: a band over the rail for a guest with something to
    -- lose, wherever the drawer is standing at home. It used to carry a dot
    -- on the pilot stop as well and to stand down on the page it pointed at;
    -- the page is gone, so the band is the whole warning here and the dot
    -- rides the landing's account stop, which is what it now points at.
    out.banner = guest_stakes() and M.home
    out.rail_hover = M.rail_hover
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
        local go = pick and pick.go
        if go and NODES[go] then
            local nd2 = NODES[go]
            out.empty = nd2.empty and nd2.empty() or nil
            out.head = nd2.head and nd2.head() or nil
            out.lede = nd2.lede and nd2.lede() or nil
            out.rows = {}
            for i, r in ipairs(rows_of(nd2)) do
                out.rows[i] = view_row(r, i)
            end
            -- A preview of a page is that page, not a different drawing of
            -- the same rows: the ship stop previews as the roster itself,
            -- because what the tab under the cursor leads to is the thing
            -- worth showing.
            if go == "hangar" then out.ships_preview = true end
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
    -- The head takes the cursor off whichever of the two had it, and neither
    -- draws one while it is up there: one thing is lit on this panel at a
    -- time. The rail's own stop stays lit at its standing weight, because
    -- that mark says which page the panel is inside rather than where the
    -- arrows are.
    if M.head_sel then out.focus = "head" end
    -- The wash a page of settings gets. It is a reading rather than a list of
    -- rooms, and the ground under it is set for one.
    if M.showing() == "settings" then out.settings = true end
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

-- keys: {left, right, up, down, go, back} as booleans, already edge-detected
-- by the arena script: a tap can go down and up inside one frame and never
-- appear in the key state that flight reads.
--
-- Returns an action name or nil, and whether anything moved, so the caller
-- can make a noise about it.
function M.step(keys)
    -- A card can be raised from the landing with the drawer shut, and it owns
    -- the keys wherever it stands: the account acts are out there now, so a
    -- password typed on the front page is walked and sent by this same path.
    -- Everything below the card's own block needs the panel, and the block
    -- returns on every branch, so there is nothing under a card to fall into.
    if not M.open and not M.ask then return nil, false end

    -- A question owns the keys while it is up, which is the whole of what
    -- makes it a question rather than a notice: the list underneath cannot be
    -- walked, and nothing behind it can be pressed by accident.
    -- Backspace on the naming page takes a letter back off its field. Above
    -- the card check, because nothing is asking: the page is.
    if not M.ask and keys.rub and M.rub_new() then return nil, true end
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

    -- The head owns the keys while the cursor is on it, the way the rail owns
    -- them at the root: it is a row, so it reads its own axis. Left and right
    -- walk the x and the call sign and loop between them, down goes back into
    -- the page it stands over, and enter presses what it is on.
    --
    -- Up does nothing, because this is the top of the column and there is
    -- nothing over it. The way back to the rail is down through the page, the
    -- same walk that reached the head in the first place.
    if M.head_sel then
        local stops = head_stops()
        local hn = #stops
        -- The row is shorter in a match than it is at home, and the call sign
        -- goes off it when a pilot leaves the front end with the cursor on it.
        if M.head_sel > hn then M.head_sel = hn end
        if keys.back then
            M.head_sel = nil
            return escape()
        end
        if keys.left then
            M.head_sel = (M.head_sel - 2) % hn + 1
            return nil, true
        end
        if keys.right then
            M.head_sel = M.head_sel % hn + 1
            return nil, true
        end
        if keys.down then
            M.head_sel = nil
            -- Back onto the page, at the top of it, which is where a step
            -- down from the line over it lands. On a page whose first control
            -- is a field that is the field, since the box is what is under
            -- this line.
            if n > 0 then M.sel[id] = first_stop(rows) end
            return nil, true
        end
        if keys.go then
            local act, moved = press_head(stops[M.head_sel])
            -- Everything on this row either shuts the panel or opens a page,
            -- and both leave the row. Left standing, the cursor would still be
            -- up here when the next page drew.
            if moved then M.head_sel = nil end
            return act, moved
        end
        return nil, false
    end

    -- A page can hold nothing at all: the games, before a directory has
    -- answered. Escape and left still work; there is no row for anything else
    -- to move to, and a cursor stepped round a list of none is a nan.
    if n == 0 then
        if keys.back then return escape() end
        if keys.left then return back() end
        return nil, false
    end

    -- The tab row reads its own axis, which is the row's own: left and right
    -- walk the tabs, and up and down walk into the page over them.
    --
    -- This was up and down while the tabs were a column down the left. The
    -- keys follow the drawing rather than the tree, which is what makes the
    -- same five inputs work on a keyboard, a d-pad and a thumb without a
    -- second layout: an arrow means the direction it points.
    --
    -- The row is the tabs and nothing else, and it loops. The x and the call
    -- sign were on the end of it for a while, so that right off the last tab
    -- crossed the whole height of the column to a button drawn at the top of
    -- it. They are their own row now, over the page rather than beside the
    -- rail. See `head_stops`.
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
        if keys.go or keys.down or keys.up then
            -- Up as well as down. The page is drawn above the stops, so up is
            -- the direction it is in: a hand that walked out of the foot of a
            -- list by pressing down has to be able to walk back in.
            --
            -- Silent where the page is still coming. A tick under a press
            -- that changed nothing is the menu saying it did something.
            local r = rows[row_index(rows)]
            if r and r.go and not enterable(r.go) then return nil, false end
            local act = activate()
            -- An arrow is a step in a direction, so where it lands is decided
            -- by which end of the list it came in at: up walks in from
            -- underneath and lands on the last row, down walks in from over
            -- the top and lands on the first. Both used to land wherever the
            -- page was last left, which is how pressing down on `ship` came to
            -- light `wake`: the press before it had been an up.
            --
            -- Enter is the one press that is not a direction, so it is the one
            -- that still lands where the page was left, and the one that opens
            -- a page whose first control is a field with the cursor in it.
            if (keys.up or keys.down) and #M.stack > 1 then
                local into = M.stack[#M.stack]
                local page = rows_of(node())
                if #page > 0 then
                    M.sel[into] = keys.up and next_stop(page, 1, -1)
                        or first_stop(page)
                end
            end
            return act, true
        end
        return nil, false
    end

    -- A grid reads its own arrows. Everywhere else right is enter, which is
    -- what a one-column list wants and exactly wrong on a page laid out in
    -- four: pressing right to look at the hull beside this one flew it
    -- instead, and down, which should have gone to the row below, went one
    -- ship to the right. Enter is still the only thing that picks.
    if nd.grid and #M.stack > 1 and n > 0 then
        -- The hull page is as wide as the column lets it be and says so every
        -- frame. It is the only page laid out in two dimensions now: the
        -- controls were the other, three chips across under a picture of a
        -- keyboard, and both went when the menu became one column.
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
    -- Every slot is a ladder, including the add-ons that used to be chips in
    -- a row of boxes across the page. Left and right walked those boxes,
    -- because that is how the drawing read; one row grammar means one answer
    -- to what an arrow does, and it is the one a range wants.
    local ranged = here ~= nil and here.choice ~= nil and here.act ~= nil
    if keys.left then
        if ranged then return activate(-1), true end
        return back()
    end
    if keys.right then
        if ranged then return activate(1), true end
        -- Right is enter on a list of places, which is what a one-column list
        -- of them wants. The exception was the games list, where an arrow
        -- reading down the rows must not fly you into the one it lands on;
        -- that list is the landing's now, and it walks by its own rules.
        return activate(), true
    end

    -- Landing on a row is not a choice. It was, while the list behind the
    -- ship page was a library of kits and moving the cursor loaded each in
    -- turn; the roster is a list of ships and picking one is a press.
    local function landed()
        return nil, true
    end
    if keys.up then
        -- Off the first row and onto the head, which is what is drawn over
        -- the page: the x at one end of that line and the call sign at the
        -- other. It went back to the tabs, which are along the foot, so the
        -- one control a hand on the arrows could not reach was the one at the
        -- top of the panel. A list that wrapped from its head to its foot had
        -- the same fault a step earlier.
        if row_index(rows) == 1 then
            M.head_sel = #head_stops()
            return nil, true
        end
        M.sel[id] = next_stop(rows, row_index(rows), -1)
        return landed()
    end
    if keys.down then
        -- Off the last row and onto the stops. The list wrapped from its foot
        -- back to its head, which made the page a ring a hand could not get
        -- out of downward: the tabs are drawn under it and down is where they
        -- are, so down is how they are reached.
        local at = row_index(rows)
        local nxt = next_stop(rows, at, 1)
        if nxt <= at then return back() end
        M.sel[id] = nxt
        return landed()
    end
    if keys.go then return activate(), true end
    return nil, false
end

-- A triangle beside the wake row, pressed: one step round the wakes,
-- wrapping. The one control of its shape left on the page, since the roster
-- stopped being a carousel of one hull and became the list it is now.
function M.click_wake(dir)
    M.wake = (M.wake + (dir or 1)) % #M.WAKES
    M.save_identity()
    return nil, true
end

-- Which of the head's controls the arrows are on, as an index into
-- `head_stops`. Nil is the usual answer: the cursor is on a tab or somewhere
-- in a page, and the head is a line the arrows visit rather than pass
-- through.
M.head_sel = nil

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
    -- A tap on a tab takes the cursor off the head, so the panel never looks
    -- like the arrows are in two places.
    M.head_sel = nil
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
        if rows[index] then
            M.sel[M.stack[#M.stack]] = index
            -- The cursor is one cursor. A pointer resting on a row takes it
            -- off the line over the page the same way an arrow would.
            M.head_sel = nil
        end
    end
    return index ~= nil
end

-- The rail is not that. A pointer resting on a stop lights it and does
-- nothing else, at every depth.
--
-- It used to move the cursor at the root, on the same "the hover is the
-- cursor where the cursor lives" reading the stage uses, and the cursor lives
-- in the rail while the stage is only a preview. What that produced was a tab
-- row that changed the page under the mouse sometimes and not others, and the
-- rule for which was invisible: walk into a page with the arrows and the rail
-- went quiet, come back out and it started switching again. Two behaviors
-- from one gesture, told apart by how you got there.
--
-- So one rule instead, and two marks rather than one: the lit stop is where
-- you are, as it always was, and the hover is a second mark saying what a
-- press would open. Crossing the row on the way to somewhere else cannot take
-- a page off the screen, and the mouse still reaches every tab in one click.
function M.hover_rail(index)
    if index == M.rail_hover then return false end
    M.rail_hover = index
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
    M.head_sel = nil
    return activate(), true
end

-- A pointer landed on a row the interface published.
function M.click(index)
    if not M.open then return nil, false end
    if not row_at(index) then return nil, false end
    M.sel[M.stack[#M.stack]] = index
    M.head_sel = nil
    return activate(), true
end

-- The x on the panel. It shuts the menu rather than stepping back a level,
-- which is what a cross means everywhere else, and it is drawn only where
-- there is a game behind to shut it onto.
function M.click_close()
    if not M.open then return nil, false end
    return nil, M.close()
end

-- Whether there is a level to come back out of, which is what a swipe right
-- asks before it takes the gesture off the page under it. A page one level in
-- came in from the right; the root came from nowhere.
function M.can_back()
    return M.open and #M.stack > 1
end

-- The chevron a drilled-into page wears on a phone. One level up, which is
-- what escape does from the same place; a chevron is that press for a thumb.
function M.click_back()
    if not M.open or #M.stack < 2 then return nil, false end
    table.remove(M.stack)
    M.head_sel = nil
    return nil, true
end

return M
