-- The key bindings: what may be bound, where things start, and what happens
-- when two controls want one key.
--
--     lua5.1 client/tests/binds_test.lua
--
-- A key in the catalog with no trigger in game.input_binding is a key the page
-- will offer and the engine will never report. A control missing from the
-- arena's route object is a row that claims a key does something it does not.
-- A bad swap can leave a control on no key at all, which is the one state this
-- design exists to make impossible.

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

local keys = require("arena.keys")
local controls = require("arena.controls")
local binds = require("arena.binds")

local function read(path)
    local f = io.open(path)
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

-- --- the catalog and the engine agree --------------------------------------

do
    local src = read("client/main/game.input_binding")
    check("the bindings can be read", src ~= nil)
    src = src or ""

    -- Every trigger in the file, as input -> action.
    local bound = {}
    for input, action in src:gmatch("input:%s*(%S+)%s*\n%s*action:%s*\"([^\"]+)\"") do
        bound[action] = bound[action] or {}
        bound[action][input] = true
    end

    local missing = {}
    for _, k in ipairs(keys.list) do
        local have = bound[k.action]
        if not (have and have[k.input]) then
            missing[#missing + 1] = k.id .. " (" .. tostring(k.input) .. ")"
        end
        if k.alt and not (have and have[k.alt]) then
            missing[#missing + 1] = k.id .. " (" .. k.alt .. ")"
        end
    end
    check("every bindable key has a trigger", #missing == 0,
          table.concat(missing, ", "))

    -- And nothing the other way: a `k_` action with no key behind it is a
    -- press that arrives and is routed to nothing.
    local stray = {}
    for action in pairs(bound) do
        if action:sub(1, 2) == "k_" then
            local found = false
            for _, k in ipairs(keys.list) do
                if k.action == action then found = true end
            end
            if not found then stray[#stray + 1] = action end
        end
    end
    check("and no trigger names a key the catalog has dropped", #stray == 0,
          table.concat(stray, ", "))

    -- The file is generated. Regenerating it has to be a no-op, or the
    -- committed copy is somebody's hand edit and the next run of the tool
    -- will quietly undo it.
    local gen = io.popen("lua5.1 client/tools/input_binding.lua 2>/dev/null")
    local fresh = gen and gen:read("*a") or ""
    if gen then gen:close() end
    -- `print` adds the trailing newline the committed file carries.
    check("the committed binding file is what the tool writes",
          fresh ~= "" and fresh == src,
          "run: lua5.1 client/tools/input_binding.lua > "
          .. "client/main/game.input_binding")
end

-- --- and the catalog and the list of controls agree ------------------------

do
    local unknown, seen, twice = {}, {}, {}
    for _, c in ipairs(controls) do
        for _, key in ipairs(c.keys) do
            if not keys.by_id[key] then
                unknown[#unknown + 1] = c.id .. " -> " .. tostring(key)
            end
        end
        local at = table.concat(c.keys, "+")
        if seen[at] then twice[#twice + 1] = at end
        seen[at] = true
    end
    check("every control starts on keys that exist", #unknown == 0,
          table.concat(unknown, ", "))
    check("and no two controls start on the same chord", #twice == 0,
          table.concat(twice, ", "))

    -- This is the route object arena.script consumes. An identity hash makes
    -- its action values readable here without substituting a second routing
    -- implementation for the one the game uses.
    local fake_sim = {
        BTN_LEFT = 1, BTN_RIGHT = 2, BTN_THRUST = 4, BTN_REVERSE = 8,
        BTN_FIRE = 16, BTN_BOMB = 32, BTN_MULTI = 64,
        KIT_CHARGE_SLOTS = 2,
    }
    local route = require("arena.control_actions").new(function(id) return id end,
                                                        fake_sim)
    local handled, mismatched, duplicate = {}, {}, {}
    local function consume(id, action)
        if action ~= id then
            mismatched[#mismatched + 1] = id .. " -> " .. tostring(action)
        end
        if handled[action] then
            duplicate[#duplicate + 1] = tostring(action)
        end
        handled[action] = true
    end
    for id, flight in pairs(route.flight) do consume(id, flight.action) end
    for _, charge in ipairs(route.charge) do consume(charge.id, charge.action) end
    for id, action in pairs(route.panel) do consume(id, action) end
    for _, move in ipairs(route.players) do consume(move.id, move.action) end
    check("every route sends the control it names", #mismatched == 0,
          table.concat(mismatched, ", "))
    check("and no two controls send the same action", #duplicate == 0,
          table.concat(duplicate, ", "))
    local handless, offered = {}, {}
    for _, c in ipairs(controls) do
        offered[c.id] = true
        if not handled[c.id] then handless[#handless + 1] = c.id end
    end
    check("and the arena routes every control it offers", #handless == 0,
          table.concat(handless, ", "))
    local stale = {}
    for id in pairs(handled) do
        if not offered[id] then stale[#stale + 1] = id end
    end
    table.sort(stale)
    check("and no route names a control the catalog has dropped", #stale == 0,
          table.concat(stale, ", "))

    -- The same dispatcher the frame loop calls consumes every panel route.
    -- Its fixed order includes the player movement gap, so this also pins the
    -- behavior when two panel keys land in one frame.
    local tapped, delivered = {}, {}
    for _, action in pairs(route.panel) do tapped[action] = true end
    local handlers = {}
    for _, id in ipairs({"menu", "details", "map", "help"}) do
        local name = id
        handlers[name] = function() delivered[#delivered + 1] = name end
    end
    handlers.players = function() delivered[#delivered + 1] = "players" end
    route.dispatch_panel(tapped, route.panel, handlers, true)
    check("the panel dispatcher consumes every route",
          next(tapped) == nil,
          next(tapped) and tostring(next(tapped)) or nil)
    check("and preserves panel action order",
          table.concat(delivered, ",") == "menu,details,players,map,help",
          table.concat(delivered, ","))

    tapped[route.panel.menu] = true
    handlers.menu = function() return false end
    route.dispatch_panel(tapped, route.panel, handlers, true)
    check("a deferred panel action remains pending",
          tapped[route.panel.menu] == true)
end

-- --- swapping ---------------------------------------------------------------

local function key_of(id)
    local chord = binds.chord_of[id]
    return chord and table.concat(chord, "+")
end

local function nothing_unbound()
    for _, c in ipairs(controls) do
        local at = key_of(c.id)
        if not at then return c.id end
        if binds.control_of[at] ~= c.id then
            return c.id .. " is not what its chord points back to"
        end
    end
    return nil
end

do
    binds.reset()
    check("it starts where controls.lua says", key_of("thrust") == "up"
          and key_of("guns") == "d")

    -- A free key: nothing displaced.
    local moved, ok = binds.set("thrust", {"j"})
    check("a control moves to a free key", ok and moved == nil
          and key_of("thrust") == "j")
    check("and its old key is free", binds.control_of["up"] == nil)

    -- A taken key: the two trade, and both keep one.
    binds.reset()
    local other = binds.set("thrust", {"w"})
    check("a taken key trades", other == "charge_1"
          and key_of("thrust") == "w" and key_of("charge_1") == "up",
          tostring(other) .. " / " .. tostring(key_of("charge_1")))
    check("and nothing is left unbound", nothing_unbound() == nil,
          tostring(nothing_unbound()))

    -- The key it is already on: nothing happens, and it says so.
    binds.reset()
    local _, changed = binds.set("guns", {"d"})
    check("binding a control to the key it is on changes nothing",
          changed == false and key_of("guns") == "d")

    -- Escape is not anybody's to take, in either direction.
    binds.reset()
    local _, took = binds.set("menu", {"j"})
    check("the menu key cannot be moved",
          took == false and key_of("menu") == "esc")
    local _, stole = binds.set("map", {"esc"})
    check("and nothing can be moved onto it",
          stole == false and key_of("map") == "m")

    -- A key that is not in the catalog at all.
    binds.reset()
    local _, wild = binds.set("map", {"f13"})
    check("a key the catalog does not carry is refused",
          wild == false and key_of("map") == "m")
end

-- --- routing ----------------------------------------------------------------
--
-- The whole reason the rest of the client knows nothing about any of this: a
-- press on a key arrives under the name of the thing the key does.

local function press(held, ...)
    local down = {}
    for _, a in ipairs({...}) do down[a] = true end
    for k in pairs(held or {}) do down[k] = true end
    local last = select(select("#", ...), ...)
    return binds.on_press(last, down)
end

do
    binds.reset()
    check("a press routes to what is on the key",
          press(nil, "k_d") == "guns"
          and press(nil, "k_up") == "thrust")
    binds.set("thrust", {"w"})
    check("and follows it when it moves",
          press(nil, "k_w") == "thrust"
          and press(nil, "k_up") == "charge_1")
    check("a key with nothing on it routes nowhere",
          press(nil, "k_f") == nil)
    check("and so does an action that is not a key",
          press(nil, "select") == nil)
end

-- --- chords -----------------------------------------------------------------
--
-- Two controls may share a trigger as long as their modifiers differ, so a
-- player can put a control on Shift and the bomb key while the bomb key alone
-- stays the bomb.
--
-- Nothing ships on a chord any more; the mechanism stays because a player may
-- still want one.

do
    binds.reset()
    binds.set("map", {"shift", "a"})
    check("a chord binds without taking the bare key",
          key_of("map") == "shift+a" and key_of("bombs") == "a",
          tostring(key_of("map")) .. " / " .. tostring(key_of("bombs")))
    check("the bare trigger is still the bomb",
          press(nil, "k_a") == "bombs")
    check("and the chord beats it when the modifier is down",
          press({k_shift = true}, "k_a") == "map")
    check("while the modifier on its own is nobody's",
          press(nil, "k_shift") == nil)

    -- Order is the hand's, not the list's: the same two keys are one binding
    -- however they were typed.
    local _, ok = binds.set("details", {"a", "shift"})
    check("a chord typed backwards is the same chord",
          ok and key_of("details") == "shift+a", tostring(key_of("details")))
    check("and it displaced the control that was on it",
          key_of("map") == "p", tostring(key_of("map")))

    -- A chord and its own trigger are different bindings, so putting one on a
    -- key the other already uses is not a conflict.
    binds.reset()
    local moved2 = binds.set("map", {"shift", "d"})
    check("a chord over a bare key displaces nothing", moved2 == nil
          and key_of("guns") == "d" and key_of("map") == "shift+d")
    check("and both still route", press(nil, "k_d") == "guns"
          and press({k_shift = true}, "k_d") == "map")
end

-- --- saving -----------------------------------------------------------------

do
    binds.reset()
    check("a stock keyboard saves nothing at all",
          binds.save_table() == nil)

    binds.set("thrust", {"w"})
    local saved = binds.save_table()
    check("a moved key is saved",
          saved ~= nil and saved.thrust and saved.thrust[1] == "w")
    check("and so is the one it displaced",
          saved ~= nil and saved.charge_1 and saved.charge_1[1] == "up")

    binds.reset()
    binds.load(saved)
    check("and reading it back puts them where they were",
          key_of("thrust") == "w" and key_of("charge_1") == "up")

    -- A chord survives the trip as well, which is the case a list has over a
    -- string and the reason the file holds one.
    binds.reset()
    binds.set("map", {"shift", "j"})
    binds.load(binds.save_table())
    check("and a chord comes back as a chord",
          key_of("map") == "shift+j", tostring(key_of("map")))

    -- A file from a build that carried keys this one does not. Honored, it
    -- would bind a control to a press that can never arrive.
    binds.load({thrust = {"f13"}, map = {"z"}})
    check("a saved key this build has dropped is discarded",
          key_of("thrust") == "up" and key_of("map") == "z")

    -- And a file written before chords existed, where a binding was one key.
    binds.load({map = "z"})
    check("a bare key in an older file is read as a chord of one",
          key_of("map") == "z", tostring(key_of("map")))

    binds.load("not a table")
    check("and rubbish in the file is the defaults", key_of("thrust") == "up")
    check("with nothing unbound after any of it",
          nothing_unbound() == nil, tostring(nothing_unbound()))
end

binds.reset()

if fails > 0 then
    print(fails .. " failed")
    os.exit(1)
end
print("all good")
