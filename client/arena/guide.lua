-- What the game says to somebody who has not played it before.
--
--     lua5.1 client/tests/guide_test.lua
--
-- The interface already explains itself, on two terms. Point at an instrument
-- and it names itself, which is a question you can only ask once you suspect
-- the instrument is there. Open the menu and there is a picture of a keyboard,
-- which is a thing you go and consult. Neither reaches a pilot in their first
-- thirty seconds, because in their first thirty seconds they are flying.
--
-- This is the third term: the same label, hovered by the game. ui.lua draws it
-- exactly the way it draws the pointer's answer, a bar in the thing's color
-- with the words beside it, so nothing new appears on screen and nothing new
-- has to be learned in order to read what is on it.
--
-- Two kinds of line, and the split is what keeps this from being a tutorial
-- with a skip button on it.
--
-- An **ask** is about your hands: something you have not done, named with the
-- control that does it. It retires when you do the thing, not on a timer, and
-- it retires whether or not it was ever shown. Somebody who has played this
-- kind of game before will steer and shoot inside five seconds, so their whole
-- ask chain retires unseen. That is the point of doing it this way rather than
-- as a scripted opening: the people who need it get it and the people who do
-- not are never interrupted.
--
-- A **tell** is about the world: something that has just happened to you for
-- the first time. It fires on its event and comes down on a clock. Where the
-- thing has a card in ui.CARDS, the tell names the card rather than carrying
-- its own words, so learning what a bomb is from the guide and then pointing
-- at the BOMB row is learning it in the same sentence twice.
--
-- Asks wait for quiet. Tells fire on their event, because the event is the
-- reason they are worth reading.

local M = {}

-- Where what has been seen is kept. Its own file rather than a field in the
-- pilot save, because this is about the person at the keyboard and not about
-- the call sign they are flying under: somebody who rerolls a name has not
-- forgotten which key fires.
local SAVE = sys.get_save_file("vectorwake", "guide")

-- The floor between two lines, in seconds. Anything shorter reads as a list
-- being played at you rather than as the game answering something that just
-- happened.
local GAP = 4
-- How long a tell stays up. Long enough to read twice at the speed somebody
-- reads while also flying, which is most of what this has to survive.
local HOLD = 8
-- A queued tell older than this is dropped rather than shown. The moment it
-- was about has gone, and a sentence about a green you collected fifteen
-- seconds ago is a sentence about nothing.
local STALE = 10

-- --- what a line looks like ------------------------------------------------
--
-- `at` is an anchor ui.lua knows: an instrument by the name the hover label
-- files it under, or "ship" for your own hull, which is where anything about
-- flying belongs. There is no instrument for "left and right turn", and a
-- sentence about your ship set out in a corner is a sentence about the corner.
--
-- `card` names an entry in ui.CARDS and `text` carries its own words; a line
-- has one or the other. Neither is resolved here, because which sentence a
-- device gets is a fact about the device and ui.lua is the end that knows.

-- The chain, in order. Each step waits for the one before it to retire, so a
-- pilot is never asked to fire while they are still working out which way is
-- forward.
local CHAIN = {"steer", "fire", "bomb"}

local ASKS = {
    steer = {
        at = "ship",
        text = "Left and right turn your ship. Up goes forward, " ..
               "down goes backwards.",
        pad = "Point the left thumb where you want the nose, then push it " ..
              "out to thrust.",
        -- Both halves, because they are two different ideas wearing one row
        -- of keys. Turning is obvious and thrust is not: a player who has met
        -- four-way movement before will hold left and wait to move left.
        done = function(c) return c.turned and c.thrusted end,
    },
    fire = {
        at = "gun",
        text = "Space fires your guns. Every shot spends energy, and energy " ..
               "is also your armor.",
        pad = "The big pad on the right fires your guns. Every shot spends " ..
              "energy, and energy is also your armor.",
        -- The one thing the corner stack cannot say for itself. Its pip
        -- empties when you are shot, which teaches that energy is armor; that
        -- firing spends the same pool is invisible until somebody says it.
        done = function(c) return c.fired end,
    },
    bomb = {
        at = "bomb",
        text = "Tab fires a bomb. Slower than a bullet and takes more " ..
               "energy, but does more damage.",
        pad = "The smaller pad beside the guns fires a bomb. Slower than a " ..
              "bullet and takes more energy, but does more damage.",
        -- Two of the hulls carry no rack at all, and an instruction to press
        -- a key that does nothing is worse than saying nothing.
        due = function(c) return c.has_bomb end,
        done = function(c) return c.bombed end,
    },
    charge = {
        -- Filled in when it fires, since which slot is in hand decides both
        -- the anchor and the sentence.
        at = "ship",
        due = function(c) return c.charge_name ~= nil end,
        done = function(c) return c.spent_charge end,
        -- A charge says what it is out of the glossary and which key spends
        -- it out of the same place, so this carries no words of its own.
        card = function(c) return c.charge_name end,
        anchor = function(c) return "charge:" .. c.charge_name end,
    },
    -- The one ask that is urgent. Riding somebody else's ship is a state a
    -- pilot can arrive in without meaning to, and until they know the key
    -- they are a passenger: their own controls do nothing to where they are
    -- going. It jumps the queue for that reason, and for no other.
    drop = {
        at = "ship",
        text = "You are riding someone else's ship. Press D to detach.",
        pad = "You are riding someone else's ship. Your own row on the " ..
              "scoreboard carries DROP.",
        due = function(c) return c.riding end,
        done = function(c) return c.dropped or not c.riding end,
    },
    map = {
        at = "radar",
        text = "M toggles a larger map so you can see the whole arena.",
        pad = "Tap the dial to toggle a larger map so you can see the whole " ..
              "arena.",
        -- Not in the first minute. The dial covers the fight you are in and
        -- the map answers a question nobody has yet: a pilot who has not been
        -- anywhere does not want to know where they have been.
        due = function(c) return c.flown > 90 or c.spawns >= 2 end,
        done = function(c) return c.mapped end,
    },
    players = {
        at = "ship",
        text = "P lists everyone here. Select a teammate and click ATTACH " ..
               "to become a gunner on their ship.",
        pad = "Tap the scoreboard for everyone here. Select a teammate and " ..
              "tap ATTACH to become a gunner on their ship.",
        due = function(c) return c.others > 0 end,
        done = function(c) return c.listed end,
    },
}

-- --- the tells -------------------------------------------------------------
--
-- Written out rather than generated, except where one add-on lands on either
-- trigger and the only difference is which word to use for the round and which
-- key throws it. Those two facts come off the trigger, so the sentence is
-- built once and the trigger fills it in.

-- What a trigger's rounds are called and how they leave the ship, which is
-- everything the mod lines need to know about which trigger they landed on.
local TRIG = {
    [0] = {noun = "bullets", at = "gun",
           key = "Space fires them.",
           pad = "The big pad on the right fires them."},
    [1] = {noun = "bombs", at = "bomb",
           key = "Tab fires them.",
           pad = "The smaller pad beside the guns fires them."},
}

-- One add-on, said for whichever trigger picked it up.
local function mod_tell(t, body)
    local w = TRIG[t] or TRIG[0]
    return {at = w.at,
            text = body:gsub("<rounds>", w.noun) .. " " .. w.key,
            pad = body:gsub("<rounds>", w.noun) .. " " .. w.pad}
end

local MOD_BODY = {
    -- Multifire is the one that arrives switched on, so its line is about
    -- turning it off. It is also the one add-on that is not always an
    -- upgrade: on a hull with two barrels it has measured as a straight loss,
    -- because a wider fan out of more barrels is a fan nothing lands from.
    [0] = false,   -- multi, which has a line of its own below
    [1] = "Your <rounds> bounce off walls now.",
    [2] = "Your bombs have a fuse now, so they go off near a ship instead " ..
          "of waiting to touch one.",
    [3] = false,   -- shrapnel, which has a card
    [4] = "Your <rounds> stall a recharge. Whoever they land on stops " ..
          "getting energy back for a moment.",
    [5] = "Your <rounds> shove. A repel welded onto something that also " ..
          "does damage.",
}

-- The rest, keyed by id. `card` and `text` as above.
local TELLS = {
    green = {at = "ship", card = "green"},
    stat = {at = "ship",
            text = "The green improved your ship's capabilities. You'll " ..
                   "keep the upgrades until you lose your ship."},
    gun_rung = {at = "gun",
                text = "Your guns improved. Each bullet does more damage, " ..
                       "but takes more energy. Space fires them.",
                pad = "Your guns improved. Each bullet does more damage, " ..
                      "but takes more energy. The big pad on the right " ..
                      "fires them."},
    bomb_rung = {at = "bomb",
                 text = "Your bombs improved. They have a wider blast, and " ..
                        "do more damage. Tab fires them.",
                 pad = "Your bombs improved. They have a wider blast, and " ..
                       "do more damage. The smaller pad beside the guns " ..
                       "fires them."},
    -- The one line that cannot be written for a touchscreen, because a
    -- touchscreen has no control for it: the pads carry the two triggers and
    -- the charges and nothing else. Said anyway, minus the way out of it,
    -- since a player whose gun has started fanning is owed the reason.
    multi = {at = "gun",
             text = "Multifire is on. Your gun fans wider and each pull " ..
                    "costs more, which is not always the better trade. " ..
                    "Tilde turns it off.",
             pad = "Multifire is on. Your gun fans wider and each pull " ..
                   "costs more, which is not always the better trade."},
    shrapnel = {at = "bomb", card = "shrap"},
    safe = {at = "ship", card = "safe"},
    hole = {at = "ship", card = "hole"},
    door = {at = "ship",
            text = "A door shut on you, so you were warped to a new " ..
                   "location. Doors open and close periodically."},
    flag = {at = "ship",
            text = "You are carrying a flag. Whoever kills you gets paid " ..
                   "for it on top of your bounty."},
    -- Somebody arriving on your ship is the most surprising thing that can
    -- happen to a pilot who has not read the design doc: the ship grows
    -- drones, gets slower, and starts firing weapons you did not fire.
    boarded = {at = "ship",
               text = "Somebody is a gunner on your ship. They aim and fire " ..
                      "for themselves, you do the flying. Your thrust and " ..
                      "top speed drop while gunners are aboard."},
    bounty = {at = "bounty", card = "bounty"},
    loss = {at = "ship",
            text = "Everything you were carrying went with the ship. " ..
                   "Collect greens to improve your ship again."},
    sides = {at = "ship",
             text = "Your teammates are blue. Enemy ships are orange. Their " ..
                    "name color shows their team."},
}

-- --- state -----------------------------------------------------------------

local seen = {}       -- id -> true, and the only thing that is written out
local pending = {}    -- tells waiting for the floor between lines to pass
local live = nil      -- what is on screen, or nil
local now = 0
local free_at = 0     -- the earliest a new line may go up
-- What the pilot has done, which is what retires an ask. Kept across deaths
-- and rooms within a session: pressing a key is a thing you have learned, not
-- a thing about the ship you were flying when you learned it.
local did = {}
local flown = 0       -- seconds this pilot has been alive in a room
local spawns = 0
local was_alive = false

local function load()
    local ok, d = pcall(sys.load, SAVE)
    if ok and type(d) == "table" and type(d.seen) == "table" then
        seen = d.seen
    end
end

local function store()
    pcall(sys.save, SAVE, {seen = seen})
end

load()

-- --- queueing --------------------------------------------------------------

-- Say something, once ever. Everything funnels through here, so "once ever"
-- is one rule in one place rather than a check at each of seventeen sites.
local function say(id, line, over)
    if seen[id] or not line then return end
    -- Marked on the way in rather than on the way out. A tell that is queued
    -- and then goes stale has still been spent: it fired on a first green and
    -- there is no second first green to fire it again.
    seen[id] = true
    store()
    local e = {id = id, at = over and over.at or line.at,
               card = over and over.card or line.card,
               text = over and over.text or line.text,
               pad = over and over.pad or line.pad,
               queued = now}
    pending[#pending + 1] = e
end

-- --- reading the arena -----------------------------------------------------

-- Everything the core reports this frame that is about you. Prizes carry the
-- flat prize index rather than a category, which is what makes a line per
-- add-on possible at all: the core says exactly which green it was.
local function events(c)
    local me = c.me
    for i = 0, sim.event_count() - 1 do
        local ty, a, b, v = sim.event_at(i)
        -- v is the delta: a green can rust, taking an upgrade instead of
        -- giving one, and the zone's chance of that is small but real. A
        -- pilot whose first green robbed them must not be told greens
        -- upgrade their ship at that exact moment; the next green teaches.
        if ty == sim.EV_PRIZE and a == me and (v or 0) >= 0 then
            say("green", TELLS.green)
            if b < sim.UP_COUNT then
                say("stat", TELLS.stat)
            elseif b < sim.PRIZE_MOD0 then
                local t = b - sim.PRIZE_LEVEL0
                say(t == sim.TRIG_BOMB and "bomb_rung" or "gun_rung",
                    t == sim.TRIG_BOMB and TELLS.bomb_rung or TELLS.gun_rung)
            elseif b < sim.PRIZE_CHARGE0 then
                local k = b - sim.PRIZE_MOD0
                local t = math.floor(k / sim.MOD_COUNT)
                local m = k % sim.MOD_COUNT
                if m == sim.MOD_MULTI then
                    say("multi", TELLS.multi)
                elseif MOD_BODY[m] == false then
                    say("shrapnel", TELLS.shrapnel)
                elseif MOD_BODY[m] then
                    say("mod:" .. m, mod_tell(t, MOD_BODY[m]))
                end
            end
        elseif ty == sim.EV_CHARGE and a == me then
            did.charge = true
        elseif ty == sim.EV_FIRE and a == me then
            -- Which trigger threw it is a fact about the weapon, and the
            -- buttons already said which key was down. This only has to know
            -- that something left the ship, so the ask retires on a round in
            -- the air rather than on a key that a safe zone swallowed.
            did.shot = true
        elseif ty == sim.EV_FLAG_TAKE and a == me then
            say("flag", TELLS.flag)
        elseif ty == sim.EV_WARP and a == me then
            -- One event carrying two arrivals, told apart by b. A wormhole
            -- throws you to a random start for your side; a door that shut on
            -- you puts you back at your own.
            if b == 1 then say("hole", TELLS.hole) else say("door", TELLS.door) end
        elseif ty == sim.EV_DEATH and a == me then
            -- Only where there was something to lose. A pilot killed on the
            -- way out of the spawn has not learned what death costs, because
            -- this time it cost nothing.
            if c.carrying then say("loss", TELLS.loss) end
        end
    end
end

-- What the core does not announce and a frame can see for itself.
local function state(c)
    if c.in_safe then say("safe", TELLS.safe) end
    if (c.bounty or 0) > 0 then say("bounty", TELLS.bounty) end
    if c.enemy_near then say("sides", TELLS.sides) end
    if c.boarded then say("boarded", TELLS.boarded) end
end

-- --- asks ------------------------------------------------------------------

-- The asks that answer their own condition rather than queueing behind the
-- chain. A charge in hand and a second life are things that happen when they
-- happen, and holding them behind "have you fired yet" would be sequencing
-- for its own sake.
-- Drop off is not among them: it is taken before the chain, not after it.
local LOOSE = {"charge", "map", "players"}

-- The next ask owed, or nil.
--
-- A step whose thing has already been done is marked off on the way past,
-- shown or not, and that has to be written down rather than merely noticed:
-- what a pilot did this session is forgotten at the next launch, and an ask
-- silently satisfied in one session must not come back in the next.
--
-- `step` answers three things. A table is an ask to put up, false is a step
-- that is not due yet, and nil is one there is nothing to do about.
local function next_ask(c)
    local function step(id)
        local a = ASKS[id]
        if seen[id] then return nil end
        if a.done(c) then
            seen[id] = true
            store()
            return nil
        end
        if a.due and not a.due(c) then return false end
        return a
    end
    -- Drop off first, ahead of the chain and everything else. A pilot who is
    -- riding cannot answer "left and right turn your ship" anyway: their
    -- controls do nothing to where the ship is going, and the sentence would
    -- read as the game being broken. It is the only ask about a state rather
    -- than about a gap in what somebody knows.
    local urgent = step("drop")
    if urgent then return "drop", urgent end
    -- The chain in order, stopping at the first step still waiting on the
    -- player. A step not yet due holds the ones behind it, because being told
    -- to fire while you are still working out which way is forward is the wall
    -- of text this whole approach exists to avoid.
    for _, id in ipairs(CHAIN) do
        local a = step(id)
        if a then return id, a end
        if a == false then break end
    end
    for _, id in ipairs(LOOSE) do
        local a = step(id)
        if a then return id, a end
    end
    return nil
end

-- --- the frame -------------------------------------------------------------

-- What the player has done, which is what an ask is waiting on. Read off the
-- buttons rather than off the keyboard, so a thumbstick counts as steering and
-- a pad counts as firing without either of them being named here.
local function acted(c)
    local b = c.bits or 0
    local function held(bit) return math.floor(b / bit) % 2 == 1 end
    if held(sim.BTN_LEFT) or held(sim.BTN_RIGHT) then did.turn = true end
    if held(sim.BTN_THRUST) then did.thrust = true end
    if did.shot then
        -- A bomb and a bullet are one event, so which of the two asks this
        -- retires comes off the key that was down when it went out.
        if held(sim.BTN_BOMB) then did.bomb = true end
        if held(sim.BTN_FIRE) or not held(sim.BTN_BOMB) then did.fire = true end
        did.shot = false
    end
end

-- Called every frame with what the arena looks like from this seat. Returns
-- the line to draw, or nil, and ui.lua does the rest.
function M.update(dt, c)
    now = now + (dt or 0)
    if c.alive then
        flown = flown + (dt or 0)
        if not was_alive then spawns = spawns + 1 end
    end
    was_alive = c.alive and true or false

    -- Nothing while the menu is up or a card is taking typing, both of which
    -- are somebody reading something else, and nothing while watching another
    -- pilot fly, where every line this has would be about a ship that is not
    -- yours.
    if c.menu_open or c.typing or c.watching then
        live = nil
        return nil
    end

    -- Events first, then the buttons, and in that order because a round
    -- leaving the ship is reported on the tick the key was down. Read the
    -- other way round, a shot would be matched against the next frame's
    -- buttons and a tap short enough would land as neither gun nor bomb.
    events(c)
    acted(c)
    -- The world's own lines only while there is a ship to be in the world
    -- with. Dead, the only thing worth saying is what the death cost, and
    -- that one came in on the event.
    if c.alive then state(c) end

    c.turned, c.thrusted = did.turn, did.thrust
    c.fired, c.bombed = did.fire, did.bomb
    c.spent_charge, c.mapped, c.listed = did.charge, did.map, did.players
    c.dropped = did.drop
    c.flown, c.spawns = flown, spawns

    -- Down it comes: an ask when the thing has been done, a tell when its
    -- time is up.
    if live then
        if live.ask then
            if ASKS[live.id].done(c) then
                seen[live.id] = true
                store()
                live = nil
                free_at = now + GAP
            end
        elseif now >= live.until_t then
            live = nil
            free_at = now + GAP
        end
    end

    -- A tell can take the screen off an ask, and this is the one place
    -- anything interrupts anything. An ask is about something that has not
    -- happened and will still be true in a minute; a tell is about something
    -- that just did, and it has a few seconds in which it is worth reading.
    -- Without this an ask nobody answers starves every tell behind it, which
    -- is exactly the pilot who needs the tells most.
    --
    -- The ask is not marked off on the way out. It comes back when the tell
    -- is done, because it is still owed.
    if now >= free_at then
        while #pending > 0 do
            local e = table.remove(pending, 1)
            if now - e.queued <= STALE then
                e.until_t = now + HOLD
                live = e
                return live
            end
        end
    end

    if live or now < free_at then return live end

    -- Asks only while there is a ship to fly. Every one of them is about a
    -- control, and a control does nothing to a ship that is not there.
    if not c.alive then return nil end
    local id, a = next_ask(c)
    if id then
        live = {id = id, ask = true,
                at = (a.anchor and a.anchor(c)) or a.at,
                card = (type(a.card) == "function" and a.card(c)) or a.card,
                text = a.text, pad = a.pad}
    end
    return live
end

-- A control that was found. The two panels are opened by a key on one device
-- and a tap on another, and both arrive through one function in arena.script,
-- so this is told once rather than read out of a button bit that does not
-- exist on glass.
function M.acted(what)
    if what == "map" then did.map = true
    elseif what == "players" then did.players = true
    elseif what == "drop" then did.drop = true end
end

-- Leaving a room. What has been seen stays seen; what was on screen is about
-- an arena this pilot is no longer in.
function M.leave()
    pending = {}
    live = nil
    flown = 0
    was_alive = false
end

-- For the tests, and for anybody who wants to meet the game again.
function M.forget()
    seen = {}
    did = {}
    pending = {}
    live = nil
    flown = 0
    spawns = 0
    was_alive = false
    now = 0
    free_at = 0
    store()
end

M.ASKS = ASKS
M.TELLS = TELLS
M.CHAIN = CHAIN
M.GAP, M.HOLD, M.STALE = GAP, HOLD, STALE

return M
