-- The key bindings: what may be bound, where things start, and what happens
-- when two controls want one key.
--
--     lua5.1 client/tests/binds_test.lua
--
-- Three of these are the kind of thing that cannot be seen by reading. A key
-- in the catalog with no trigger in game.input_binding is a key the page will
-- offer and the engine will never report, and the pilot who picks it has
-- disarmed a control with no way to see why. A control in the list with no
-- hand for it in arena.script is a row that claims a key does something it
-- does not. And a swap that gets its arithmetic wrong leaves a control on no
-- key at all, which is the one state this design exists to make impossible.

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

    -- A control the arena never looks for is a row that says a key does
    -- something it does not. The charge keys are the one set built rather than
    -- written, since the arena walks the four slots in a loop.
    local src = read("client/arena/arena.script") or ""
    local BUILT = {charge_1 = 'hash("charge_" .. i)',
                   charge_2 = 'hash("charge_" .. i)',
                   charge_3 = 'hash("charge_" .. i)',
                   charge_4 = 'hash("charge_" .. i)'}
    local handless = {}
    for _, c in ipairs(controls) do
        local want = BUILT[c.id] or ('hash("' .. c.id .. '")')
        if not src:find(want, 1, true) then
            handless[#handless + 1] = c.id
        end
    end
    check("and the arena has a hand for every control", #handless == 0,
          table.concat(handless, ", "))
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
          and key_of("guns") == "space")

    -- A free key: nothing displaced.
    local moved, ok = binds.set("thrust", {"e"})
    check("a control moves to a free key", ok and moved == nil
          and key_of("thrust") == "e")
    check("and its old key is free", binds.control_of["up"] == nil)

    -- A taken key: the two trade, and both keep one.
    binds.reset()
    local other = binds.set("thrust", {"w"})
    check("a taken key trades", other == "charge_2"
          and key_of("thrust") == "w" and key_of("charge_2") == "up",
          tostring(other) .. " / " .. tostring(key_of("charge_2")))
    check("and nothing is left unbound", nothing_unbound() == nil,
          tostring(nothing_unbound()))

    -- The key it is already on: nothing happens, and it says so.
    binds.reset()
    local _, changed = binds.set("guns", {"space"})
    check("binding a control to the key it is on changes nothing",
          changed == false and key_of("guns") == "space")

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
          press(nil, "k_space") == "guns"
          and press(nil, "k_up") == "thrust")
    binds.set("thrust", {"w"})
    check("and follows it when it moves",
          press(nil, "k_w") == "thrust"
          and press(nil, "k_up") == "charge_2")
    check("a key with nothing on it routes nowhere",
          press(nil, "k_f") == nil)
    check("and so does an action that is not a key",
          press(nil, "select") == nil)
end

-- --- chords -----------------------------------------------------------------
--
-- Two controls may share a trigger as long as their modifiers differ, which is
-- the whole of what makes Shift+Tab a mine while Tab alone is a bomb.

do
    binds.reset()
    check("mines start on the original's own chord",
          key_of("mine") == "shift+tab", tostring(key_of("mine")))
    check("the bare trigger is still the bomb",
          press(nil, "k_tab") == "bombs")
    check("and the chord beats it when the modifier is down",
          press({k_shift = true}, "k_tab") == "mine")
    check("while the modifier on its own is nobody's",
          press(nil, "k_shift") == nil)

    -- Order is the hand's, not the list's: the same two keys are one binding
    -- however they were typed.
    binds.reset()
    local _, ok = binds.set("map", {"tab", "shift"})
    check("a chord typed backwards is the same chord",
          ok and key_of("map") == "shift+tab", tostring(key_of("map")))
    check("and it displaced the control that was on it",
          key_of("mine") == "m", tostring(key_of("mine")))

    -- A chord and its own trigger are different bindings, so putting one on a
    -- key the other already uses is not a conflict.
    binds.reset()
    local moved2 = binds.set("map", {"shift", "space"})
    check("a chord over a bare key displaces nothing", moved2 == nil
          and key_of("guns") == "space" and key_of("map") == "shift+space")
    check("and both still route", press(nil, "k_space") == "guns"
          and press({k_shift = true}, "k_space") == "map")
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
          saved ~= nil and saved.charge_2 and saved.charge_2[1] == "up")

    binds.reset()
    binds.load(saved)
    check("and reading it back puts them where they were",
          key_of("thrust") == "w" and key_of("charge_2") == "up")

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
