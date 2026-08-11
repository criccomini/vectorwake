-- The guide: what it says, when it says it, and when it stops.
--
--     lua5.1 client/tests/guide_test.lua
--
-- Everything this covers is invisible until somebody is flying, on a build
-- that takes six minutes to publish, and most of it is about a first time
-- that cannot be had twice. So the session is driven here instead: a stubbed
-- core, a stubbed save file, and frames pushed through the real M.update.
--
-- The two properties worth most are the ones that are cheapest to break. A
-- line must be said once ever, because the second showing is the one that
-- reads as the game nagging. And an ask must retire whether or not it was
-- ever shown, because that is what keeps this quiet for somebody who has
-- played the game before and is the whole argument for triggers over a
-- scripted opening.

package.path = "client/?.lua;" .. package.path

local fails = 0
local function check(name, ok, detail)
    if ok then
        print("ok   " .. name)
    else
        fails = fails + 1
        print("FAIL " .. name .. (detail and ("  -- " .. detail) or ""))
    end
end

-- --- the core, as much of it as guide.lua touches --------------------------

local events = {}
local ship = {alive = 1, bounty = 0, charge = {}, team = 0,
              x = 0, y = 0, safe = false}

local sim = {
    BTN_LEFT = 1, BTN_RIGHT = 2, BTN_THRUST = 4, BTN_REVERSE = 8,
    BTN_FIRE = 16, BTN_BOMB = 32,
    EV_FIRE = 1, EV_DEATH = 4, EV_SPAWN = 5, EV_PRIZE = 7, EV_CHARGE = 8,
    EV_FLAG_TAKE = 9, EV_WARP = 12,
    TRIG_COUNT = 2, TRIG_GUN = 0, TRIG_BOMB = 1,
    MOD_COUNT = 6, MOD_MULTI = 0, UP_COUNT = 5, MAX_CHARGES = 4,
    -- The flat prize space, laid out the way sim.h lays it out: five stats,
    -- then a rung per trigger, then an add-on per trigger per kind, then a
    -- charge per kind.
    PRIZE_LEVEL0 = 5, PRIZE_MOD0 = 7, PRIZE_CHARGE0 = 19,
    event_count = function() return #events end,
    event_at = function(i) local e = events[i + 1] return e[1], e[2], e[3], e[4] end,
    ship_count = function() return 2 end,
    ship_alive = function(i) return (i == 0 and ship.alive) or 1 end,
    ship_bounty = function() return ship.bounty end,
    ship_charge = function(_, k) return ship.charge[k] or 0 end,
    ship_team = function(i) return i == 0 and ship.team or 1 end,
    ship_x = function(i) return i == 0 and ship.x or 10000 end,
    ship_y = function(i) return i == 0 and ship.y or 10000 end,
    has_trigger = function() return true end,
    in_safe = function() return ship.safe end,
}
_G.sim = sim

-- A save file that lives in this process, so a run leaves nothing behind and
-- two runs cannot disagree. `guide.lua` reads it at require time, which is why
-- this is in place first.
local saved = nil
_G.sys = {
    get_save_file = function() return "guide-test" end,
    save = function(_, d) saved = d return true end,
    load = function() return saved or {} end,
}

local guide = require("arena.guide")

-- --- the harness -----------------------------------------------------------

-- One frame. `ctx` is merged over a living, quiet, keyboard-flying pilot
-- alone in the room, so a test names only the thing it is about. Alone
-- because the players ask is due the moment anybody else is here, and a test
-- about greens does not want it turning up in the middle.
local function frame(ctx, dt)
    local c = {me = 0, watching = false, alive = ship.alive == 1,
               menu_open = false, typing = false, bits = 0,
               has_bomb = true, in_safe = ship.safe,
               bounty = ship.bounty, others = 0}
    for k, v in pairs(ctx or {}) do c[k] = v end
    local line = guide.update(dt or (1 / 60), c)
    -- Consumed, the way the core's own buffer is: an event is reported on the
    -- tick it happened and not on every tick after it.
    events = {}
    return line
end

-- Frames until something comes up, or nil after `n` of them. Time passes at
-- the frame rate, so the gap between lines is real rather than skipped.
--
-- Only useful from a quiet screen. A line that is already up is returned by
-- the first frame, which is what `wait_for` exists for.
local function until_line(n, ctx)
    for _ = 1, n or 600 do
        local l = frame(ctx)
        if l then return l end
    end
    return nil
end

-- Frames until this particular line is up, letting whatever is on screen run
-- its course on the way. Nil if it never arrives.
local function wait_for(id, ctx, n)
    for _ = 1, n or 2400 do
        local l = frame(ctx)
        if l and l.id == id then return l end
    end
    return nil
end

-- That many seconds of frames, and whatever is up at the end of them.
local function idle(seconds, ctx)
    local out = nil
    for _ = 1, math.ceil((seconds or 1) * 60) do
        out = frame(ctx)
    end
    return out
end

local function fresh()
    guide.forget()
    events = {}
    ship.alive, ship.bounty, ship.safe = 1, 0, false
    ship.charge = {}
    ship.x, ship.y = 0, 0
end

-- Steer, fire and bomb answered, which is what the asks that wait behind the
-- chain have to get past before they are reachable.
local function past_chain()
    events = {{sim.EV_FIRE, 0, 0, 0}}
    frame({bits = sim.BTN_LEFT + sim.BTN_THRUST + sim.BTN_FIRE})
    events = {{sim.EV_FIRE, 0, 0, 0}}
    frame({bits = sim.BTN_BOMB})
end

-- --- the chain starts by itself --------------------------------------------

fresh()
local first = until_line(10)
check("a pilot who does nothing is asked to steer",
      first and first.id == "steer", first and first.id or "nothing")
check("and it is anchored on their own ship",
      first and first.at == "ship", first and tostring(first.at))
check("and it says which keys turn and which goes forward",
      first and first.text:find("Left and right")
      and first.text:find("Up goes forward"), first and first.text)

-- --- and it comes down when the thing is done ------------------------------
--
-- Not on a clock. An ask is a question about the player and the player is the
-- only thing that can answer it.

check("steering alone does not retire it",
      frame({bits = sim.BTN_LEFT}) ~= nil)
local after = frame({bits = sim.BTN_LEFT + sim.BTN_THRUST})
check("turning and thrusting does", after == nil, after and after.id)

-- --- one thing at a time, with a beat between --------------------------------

do
    local straight = frame({bits = sim.BTN_THRUST})
    check("the next ask does not arrive in the same breath", straight == nil,
          straight and straight.id)
    local fire = until_line(600)
    check("it arrives after the floor between lines has passed",
          fire and fire.id == "fire", fire and fire.id or "nothing")
    check("and it is anchored on the gun row",
          fire and fire.at == "gun", fire and tostring(fire.at))
end

-- --- a shot retires the right one of two -----------------------------------
--
-- The core reports one event for both triggers, so which ask a round retires
-- comes off the key that was down when it left. Read a frame late, a tap short
-- enough would land as neither.

do
    events = {{sim.EV_FIRE, 0, 0, 0}}
    local still = frame({bits = sim.BTN_FIRE})
    check("firing retires the gun ask", still == nil, still and still.id)
    local bomb = until_line(600)
    check("and the bomb ask follows it",
          bomb and bomb.id == "bomb", bomb and bomb.id or "nothing")
    events = {{sim.EV_FIRE, 0, 0, 0}}
    local done = frame({bits = sim.BTN_BOMB})
    check("dropping a bomb retires the bomb ask", done == nil,
          done and done.id)
end

-- --- somebody who already knows the game is never interrupted ---------------
--
-- The whole argument for asks that retire on the doing rather than on a timer.
-- A pilot who flies and shoots inside the first second should meet none of the
-- chain, and none of it should be waiting for them next session either.

do
    fresh()
    events = {{sim.EV_FIRE, 0, 0, 0}}
    local l = frame({bits = sim.BTN_LEFT + sim.BTN_THRUST + sim.BTN_FIRE})
    -- The bomb is the one step left, because one event retires one ask and
    -- nobody fires both triggers on the same tick. What matters is that the
    -- two they did answer were never put on screen to be answered.
    check("a pilot who flies and fires at once is never asked to do either",
          l == nil or l.id == "bomb", l and l.id)
    events = {{sim.EV_FIRE, 0, 0, 0}}
    local rest = frame({bits = sim.BTN_BOMB})
    check("and once they bomb, the chain is spent", rest == nil,
          rest and rest.id)
    -- What was done silently has to be written down, or the next launch, which
    -- has forgotten what this pilot did, asks all of it again.
    local kept = saved and saved.seen or {}
    check("and what they did silently is remembered",
          kept.steer and kept.fire and kept.bomb,
          "steer " .. tostring(kept.steer) .. " fire " .. tostring(kept.fire)
          .. " bomb " .. tostring(kept.bomb))
end

-- --- a ship with no bomb rack is not asked to fire one ----------------------
--
-- Two of the hulls carry none, and an instruction to press a key that does
-- nothing is worse than silence: it reads as the game being broken.

do
    fresh()
    local ctx = {has_bomb = false,
                 bits = sim.BTN_LEFT + sim.BTN_THRUST + sim.BTN_FIRE}
    events = {{sim.EV_FIRE, 0, 0, 0}}
    frame(ctx)
    local l = until_line(400, {has_bomb = false})
    check("a ship with no rack is never asked to bomb",
          l == nil or l.id ~= "bomb", l and l.id or "nothing")
end

-- --- tells fire on their event ---------------------------------------------

do
    fresh()
    -- Past the chain, so nothing is queued behind it.
    events = {{sim.EV_FIRE, 0, 0, 0}}
    frame({bits = sim.BTN_LEFT + sim.BTN_THRUST + sim.BTN_FIRE})
    events = {{sim.EV_FIRE, 0, 0, 0}}
    frame({bits = sim.BTN_BOMB})
    idle(guide.GAP + 1)

    events = {{sim.EV_PRIZE, 0, 0, 0}}   -- a stat, the first prize index
    local green = wait_for("green")
    check("a first green is named", green and green.id == "green",
          green and green.id or "nothing")
    check("and it names the card rather than carrying its own words",
          green and green.card == "green" and green.text == nil,
          green and tostring(green.card))
    -- The stat line is queued behind it rather than dropped: one green, two
    -- things worth knowing, and they arrive one at a time.
    local stat = wait_for("stat")
    check("the upgrade it carried is named after it",
          stat and stat.id == "stat", stat and stat.id or "nothing")
    check("and it says the upgrade is lost with the ship",
          stat and stat.text:find("lose your ship"), stat and stat.text)
end

-- --- and once only ---------------------------------------------------------

do
    idle(guide.HOLD + guide.GAP + 1)
    events = {{sim.EV_PRIZE, 0, 0, 0}}
    local again = until_line(400)
    check("a second green says nothing", again == nil,
          again and again.id)
end

-- --- a rust is not a lesson about upgrades ---------------------------------
--
-- A green can take instead of give, which the event says with v of -1. The
-- zone's chance of it is small, so guarding it is cheap; not guarding it is a
-- pilot whose first green robbed them being told greens upgrade their ship.

do
    fresh()
    events = {{sim.EV_PRIZE, 0, 0, -1}}
    local l = until_line(400)
    check("a rusted green teaches nothing",
          l == nil or (l.id ~= "green" and l.id ~= "stat"), l and l.id)
    -- And the lesson is still owed: the guard must not have spent it.
    events = {{sim.EV_PRIZE, 0, 0, 1}}
    l = wait_for("green")
    check("and the next honest green still does", l ~= nil, "nothing")
end

-- --- an add-on names the trigger it landed on ------------------------------
--
-- The prize index carries which trigger as well as which add-on, so a bomb
-- that starts bouncing is not described as a bullet that does.

do
    fresh()
    -- SIM_PRIZE_MOD(t, m) is PRIZE_MOD0 + t * MOD_COUNT + m. Bounce is 1.
    events = {{sim.EV_PRIZE, 0, sim.PRIZE_MOD0 + sim.MOD_COUNT + 1, 0}}
    local l = wait_for("mod:1")
    check("bounce on the bomb trigger talks about bombs",
          l and l.text:find("Your bombs bounce"), l and l.text)
    check("and points at the bomb row", l and l.at == "bomb",
          l and tostring(l.at))
    check("and names the key that fires them",
          l and l.text:find("Tab fires them"), l and l.text)
end

-- --- multifire is told, not asked ------------------------------------------
--
-- It arrives switched on, so the useful sentence is the one that says how to
-- turn it off, and that it is not always worth keeping.

do
    fresh()
    events = {{sim.EV_PRIZE, 0, sim.PRIZE_MOD0 + sim.MOD_MULTI, 0}}
    local l = wait_for("multi")
    check("multifire says how to switch it off",
          l and l.text:find("Tilde turns it off"), l and l.text)
    -- Glass has its own way out now, the fan cell in the charge rail, and
    -- the pad sentence names that rather than a key the device has not got.
    check("and on glass it names the fan cell, not the key",
          l and l.pad and l.pad:find("fan cell")
          and not l.pad:find("Tilde"), l and l.pad)
end

-- --- the two arrivals under one event code ---------------------------------
--
-- SIM_EV_WARP is a wormhole and a closing door, told apart by b alone. A
-- trigger reading the code and not the byte would name the wrong one half the
-- time.

do
    fresh()
    events = {{sim.EV_WARP, 0, 1, 0}}
    local l = wait_for("hole")
    check("a warp with b of one is the wormhole", l and l.id == "hole",
          l and l.id or "nothing")
    fresh()
    events = {{sim.EV_WARP, 0, 0, 0}}
    l = wait_for("door")
    check("a warp with b of zero is a door", l and l.id == "door",
          l and l.id or "nothing")
    check("and the door says it opens again",
          l and l.text:find("open and close periodically"), l and l.text)
end

-- --- what a death costs, only when it cost something ------------------------

do
    fresh()
    events = {{sim.EV_DEATH, 0, 1, 0}}
    local l = wait_for("loss", {carrying = false}, 400)
    check("dying with nothing aboard is not a lesson", l == nil,
          l and l.id)
    fresh()
    events = {{sim.EV_DEATH, 0, 1, 0}}
    l = wait_for("loss", {carrying = true})
    check("dying with something aboard is", l and l.id == "loss",
          l and l.id or "nothing")
end

-- --- a tell comes down on its own, an ask does not -------------------------

do
    fresh()
    events = {{sim.EV_FLAG_TAKE, 0, 0, 0}}
    local l = wait_for("flag")
    check("a flag is named", l ~= nil, "nothing")
    local gone = idle(guide.HOLD + 1)
    -- Whatever is up after the hold is a different line, not this one.
    check("and it comes down on its own clock",
          gone == nil or gone.id ~= "flag", gone and gone.id)
end

-- --- nothing while somebody is reading something else ----------------------

do
    fresh()
    check("nothing under the menu", frame({menu_open = true}) == nil)
    check("nothing while a card is taking typing", frame({typing = true}) == nil)
    check("nothing while watching another pilot", frame({watching = true}) == nil)
    -- And it comes back, rather than being spent by the frames it sat out.
    local back = until_line(200)
    check("and it is still owed once the menu shuts",
          back and back.id == "steer", back and back.id or "nothing")
end

-- --- an ask needs a ship to fly --------------------------------------------

do
    fresh()
    ship.alive = 0
    local l = until_line(200, {alive = false})
    check("a dead pilot is not asked to steer", l == nil, l and l.id)
    ship.alive = 1
end

-- --- the charge ask names the slot in hand ---------------------------------

do
    fresh()
    past_chain()
    local l = wait_for("charge", {charge_name = "repel"})
    check("holding a repel asks about the repel", l ~= nil, "nothing")
    check("and points at the repel row", l and l.at == "charge:repel",
          l and tostring(l.at))
    check("and takes its words from the repel card",
          l and l.card == "repel", l and tostring(l.card))
    events = {{sim.EV_CHARGE, 0, 0, 2}}
    local spent = frame({charge_name = "repel"})
    check("spending one retires it", spent == nil, spent and spent.id)
end

-- --- riding somebody is the one ask that cannot wait -----------------------
--
-- Every other ask is about something a pilot could go on not knowing while
-- still flying their own ship. This one is about a state they are stuck
-- inside: their controls do nothing until they know the key, so it goes to
-- the front of the queue rather than behind the chain.

do
    fresh()
    local l = wait_for("drop", {riding = true})
    check("being carried asks how to get off", l ~= nil, "nothing")
    check("and it says the key", l and l.text:find("Press D to detach"),
          l and l.text)
    check("and it arrives before the steer ask it jumped",
          l and l.id == "drop", l and l.id)
    -- Two ways off, a key and a row on the scoreboard, and both report.
    guide.acted("drop")
    local gone = frame({riding = true})
    check("pressing the key retires it", gone == nil, gone and gone.id)
end

-- And it retires itself if the ride ends before the pilot answers, since the
-- question stops meaning anything the moment they are flying their own ship.

do
    fresh()
    wait_for("drop", {riding = true})
    local off = frame({riding = false})
    check("stepping off retires it without being answered", off == nil,
          off and off.id)
end

-- --- and somebody riding you is worth a word -------------------------------

do
    fresh()
    local l = wait_for("boarded", {boarded = true})
    check("a gunner arriving on your ship is named", l ~= nil, "nothing")
    check("and it says who does the flying",
          l and l.text:find("you do the flying"), l and l.text)
    check("and warns what carrying costs",
          l and l.text:find("thrust and top speed drop"), l and l.text)
end

-- --- a mine is a charge like any other -------------------------------------
--
-- Slot 3 in the baseline, so it reaches the same ask, and its words come from
-- the same glossary the hover label reads.

do
    fresh()
    past_chain()
    local l = wait_for("charge", {charge_name = "mine"})
    check("holding a mine asks about the mine", l ~= nil, "nothing")
    check("and points at the mine row", l and l.at == "charge:mine",
          l and tostring(l.at))
    check("and takes its words from the mine card", l and l.card == "mine",
          l and tostring(l.card))
end

if fails > 0 then
    print(fails .. " failed")
    os.exit(1)
end
print("all good")
