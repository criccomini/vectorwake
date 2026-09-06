-- The gamepad: what it is bound to, and what its stick asks for.
--
--     lua5.1 client/tests/pad_test.lua
--
-- A pad input with no trigger in game.input_binding is a button the engine
-- will never report. A control with no pad button is a thing a pad cannot
-- do, which is allowed for exactly one control and is asserted here so a
-- second one cannot arrive unnoticed. And the face buttons change meaning
-- with the column up, which is a rule worth pinning since nothing else in
-- the client has one like it.

package.path = "client/?.lua;" .. package.path

_G.sim = {
    BTN_LEFT = 1,
    BTN_RIGHT = 2,
    BTN_THRUST = 4,
    BTN_REVERSE = 8,
    BTN_FIRE = 16,
    BTN_BOMB = 32,
    BTN_MULTI = 64,
}

local pad = require("arena.pad")
local controls = require("arena.controls")

local fails = 0
local function check(name, ok, detail)
    if ok then
        print("ok   " .. name)
    else
        fails = fails + 1
        print("FAIL " .. name .. (detail and ("  -- " .. detail) or ""))
    end
end

local function read(path)
    local f = io.open(path)
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function has(list, bit)
    for _, b in ipairs(list) do
        if b == bit then return true end
    end
    return false
end

-- --- the catalog and the engine agree --------------------------------------

do
    local src = read("client/main/game.input_binding") or ""
    local bound = {}
    for input, action in src:gmatch(
            "gamepad_trigger {\n%s*input:%s*(%S+)%s*\n%s*action:%s*\"([^\"]+)\"") do
        bound[input] = action
    end
    local missing, wrong = {}, {}
    for _, p in ipairs(pad.list) do
        if not bound[p.input] then
            missing[#missing + 1] = p.id
        elseif bound[p.input] ~= p.action then
            wrong[#wrong + 1] = p.id .. " -> " .. bound[p.input]
        end
    end
    check("every pad input has a trigger", #missing == 0,
          table.concat(missing, ", "))
    check("and each arrives under its own action", #wrong == 0,
          table.concat(wrong, ", "))
    local stray = {}
    for input in pairs(bound) do
        local found = false
        for _, p in ipairs(pad.list) do
            if p.input == input then found = true end
        end
        if not found then stray[#stray + 1] = input end
    end
    check("and no trigger names an input the catalog has dropped", #stray == 0,
          table.concat(stray, ", "))
end

-- --- every button is something -----------------------------------------------

do
    local offered = {}
    for _, c in ipairs(controls) do offered[c.id] = true end
    local unknown = {}
    for id, control in pairs(pad.FLIGHT) do
        if not pad.by_id[id] then unknown[#unknown + 1] = id end
        if not offered[control] then
            unknown[#unknown + 1] = id .. " -> " .. control
        end
    end
    check("every flight button is a control the game offers", #unknown == 0,
          table.concat(unknown, ", "))

    local nav = {}
    for _, action in pairs(pad.NAV) do nav[action] = true end
    unknown = {}
    for id, target in pairs(pad.MENU) do
        if not pad.by_id[id] then unknown[#unknown + 1] = id end
        if not (nav[target] or offered[target]) then
            unknown[#unknown + 1] = id .. " -> " .. target
        end
    end
    check("every menu button is a nav name or a control", #unknown == 0,
          table.concat(unknown, ", "))

    -- One control has no button, and it is the one whose whole job is to
    -- show a table of keys. Anything else missing here is a fault.
    local handless = {}
    for _, c in ipairs(controls) do
        if not pad.show(c.id) then handless[#handless + 1] = c.id end
    end
    check("only the controls table has no pad button",
          #handless == 1 and handless[1] == "help",
          table.concat(handless, ", "))

    -- The connection events are not buttons and must not be anything.
    check("connected and disconnected do nothing",
          pad.FLIGHT.connected == nil and pad.FLIGHT.disconnected == nil
          and pad.MENU.connected == nil and pad.MENU.disconnected == nil)
end

-- --- a press, with the column down and up ------------------------------------

do
    check("a key is not a pad action",
          pad.on_action("k_a", {pressed = true}) == false
          and pad.on_press("k_a", false) == nil)
    check("nothing has been seen yet", pad.seen == false)

    check("the right trigger fires", pad.on_press("pad_rtrigger", false) == "guns")
    check("and so does A, flying", pad.on_press("pad_rpad_down", false) == "guns")
    check("A walks the column when it is up",
          pad.on_press("pad_rpad_down", true) == "nav_go")
    check("B opens the players sheet flying",
          pad.on_press("pad_rpad_right", false) == "details")
    check("and is the way back with the column up",
          pad.on_press("pad_rpad_right", true) == "menu")
    check("Start is the menu key either way",
          pad.on_press("pad_start", false) == "menu"
          and pad.on_press("pad_start", true) == "menu")
    check("the d-pad is the arrows flying",
          pad.on_press("pad_lpad_up", false) == "thrust"
          and pad.on_press("pad_lpad_left", false) == "turn_left"
          and pad.on_press("pad_lpad_right", false) == "turn_right"
          and pad.on_press("pad_lpad_down", false) == "reverse")
    check("and walks the column with it up",
          pad.on_press("pad_lpad_up", true) == "nav_up"
          and pad.on_press("pad_lpad_down", true) == "nav_down"
          and pad.on_press("pad_lpad_left", true) == "nav_left"
          and pad.on_press("pad_lpad_right", true) == "nav_right")
    check("the stick is no press while flying",
          pad.on_press("pad_lstick_up", false) == nil)
    check("and walks the column with it up",
          pad.on_press("pad_lstick_up", true) == "nav_up")
    check("a trigger keeps its job with the column up",
          pad.on_press("pad_rtrigger", true) == "guns")
    check("the shoulders spend the charges",
          pad.on_press("pad_rshoulder", false) == "charge_1"
          and pad.on_press("pad_lshoulder", false) == "charge_2")
    check("Back is the map", pad.on_press("pad_back", false) == "map")
    check("Y fans the gun", pad.on_press("pad_rpad_up", false) == "multi")
end

-- --- the stick ---------------------------------------------------------------

-- A push, as the engine reports it: one action per direction, with a value,
-- delivered before the frame begins, which is the order the engine keeps.
local function push(dirs)
    for id, v in pairs(dirs) do
        pad.on_action("pad_lstick_" .. id, {value = v, gamepad = 0})
    end
    pad.begin_frame()
end

do
    push({})
    check("at rest the stick asks for nothing",
          not pad.steering() and #pad.bits(0) == 0)

    -- Heading 0 is north, screen up. A full push up is the course ahead.
    push({up = 1})
    local b = pad.bits(0)
    check("a full push ahead thrusts", has(b, sim.BTN_THRUST))
    check("and turns nothing", not has(b, sim.BTN_LEFT) and not has(b, sim.BTN_RIGHT))
    check("and the stick owns the rudder", pad.steering())

    push({right = 1})
    b = pad.bits(0)
    check("a push to the right turns right", has(b, sim.BTN_RIGHT))
    check("and does not thrust until the nose is round", not has(b, sim.BTN_THRUST))

    push({left = 1})
    check("a push to the left turns left", has(pad.bits(0), sim.BTN_LEFT))

    push({down = 1})
    b = pad.bits(0)
    check("a push behind is a turn, never a reverse",
          (has(b, sim.BTN_LEFT) or has(b, sim.BTN_RIGHT))
          and not has(b, sim.BTN_REVERSE))

    push({up = 0.4})
    b = pad.bits(0)
    check("a half push steers without lighting the engine",
          pad.steering() and not has(b, sim.BTN_THRUST))

    push({up = 0.1})
    check("a hair off center is rest", not pad.steering())

    -- A direction the engine stops mentioning is at rest next frame, without
    -- a release ever arriving.
    push({up = 1})
    pad.begin_frame()
    check("a direction that went quiet reads as rest",
          not pad.steering() and #pad.bits(0) == 0)

    check("the stick marks the pad as seen", pad.seen == true)
end

-- --- who is here ---------------------------------------------------------------

do
    check("the push counted a pad", pad.count() == 1)
    pad.on_action("pad_connected", {gamepad = 1, gamepad_connected = true})
    check("a second arrives", pad.count() == 2)
    pad.on_action("pad_disconnected", {gamepad = 0, gamepad_disconnected = true})
    check("and the first leaves", pad.count() == 1)
    check("connecting is not a press",
          pad.on_press("pad_connected", false) == nil
          and pad.on_press("pad_connected", true) == nil)
end

-- --- what a row says -----------------------------------------------------------

do
    local row = {id = "guns", show = "D"}
    check("a row names the key and then the pad's buttons",
          pad.label(row) == "D / RT, A", pad.label(row))
    check("a control with no button is the key alone",
          pad.label({id = "help", show = "H"}) == "H")
    check("the menu key is Start", pad.label({id = "menu", show = "Esc"}) == "Esc / Start")
    pad.seen = false
    check("and before a pad has spoken, every row is the key alone",
          pad.label(row) == "D")
end

if fails > 0 then
    print(fails .. " failed")
    os.exit(1)
end
print("all passed")
