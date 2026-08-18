-- What a saved pilot file is allowed to say.
--
--     lua5.1 client/tests/save_guard_test.lua
--
-- The save outlives the build that wrote it, and twice now a list it indexes
-- has changed size underneath it: the hulls were eight and are seven, and the
-- frame caps once offered a rate this build no longer has. An index that
-- survives a shrunken table is read as `TABLE[i][1]` on a nil, which raises in
-- `load_identity` -- before the menu exists, on every boot, with the offending
-- save never rewritten because the boot that would rewrite it never finishes.
-- A pcall around the call does not help: Lua evaluates an argument before the
-- call it belongs to, so the raise happens in the caller.
--
-- So this feeds `load_identity` the saves that used to brick the client and
-- asks only that it come back with something the tables can hold.

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

package.loaded["arena.account"] = {
    name = "", token = nil, claimed = false, load = function() end,
}
package.loaded["arena.net"] = {
    teams = {}, my_team = 0, may_found = false,
    my_team_name = function() return "" end,
    transport = function() return {} end,
    protocol = 5, invite = function() end,
}
package.loaded["arena.callsign"] = {
    roll = function() return "Probe 1" end,
    seed = function() end,
    generate = function() return "Probe 1" end,
}
package.loaded["arena.directory"] = {
    rows = {}, note = "", tick = function() end, aim = function() end,
    pilot_name = "",
}
package.loaded["arena.sfx"] = {ui = function() end, master_gain = function() end,
                               music_gain = function() end}

-- The saved file under test, swapped per case.
local saved = {}
local last_saved
_G.sys = {get_config_string = function(_, d) return d end,
          get_config_int = function(_, d) return d end,
          get_engine_info = function() return {version = "test"} end,
          get_save_file = function() return "/tmp/vw-save-guard-test" end,
          load = function() return saved end,
          save = function(_, d) last_saved = d return true end,
          set_update_frequency = function() return true end,
          get_sys_info = function() return {system_name = "Linux"} end}
_G.sound = setmetatable({}, {__index = function() return function() end end})
_G.html5 = nil
_G.hash = function(s) return s end

local menu = require("arena.menu")

-- The hull count this build actually has, taken from the menu rather than
-- written down again here: a test holding its own copy of the number is a
-- test that passes the day the table changes size.
-- Drawing the home screen is where a bad hull index actually lands: the root
-- rail resolves every row's detail every frame, and the ship row's detail is
-- the `HULLS[class + 1][1]` that raised. So the test for a survivable save is
-- that the menu can still be looked at afterwards.
local function root_view()
    menu.open = true
    menu.stack = {"root"}
    local ok, err = pcall(menu.view)
    menu.open = false
    return ok, err
end

local function load_with(d, name)
    saved = d
    local ok, err = pcall(menu.load_identity)
    check(name .. " does not raise", ok, tostring(err))
    if not ok then return false end
    local drawn, derr = root_view()
    check(name .. " leaves a menu that can be drawn", drawn, tostring(derr))
    return drawn
end

-- The hull. 7 is the value the old modulo-eight guard let through against a
-- seven-hull table, and it is what an unvalidated wire byte could put in a
-- save by way of the seat the zone dealt.
for _, cls in ipairs({-3, 7, 8, 99, 2.5}) do
    if load_with({name = "Probe", class = cls}, "class " .. cls) then
        check("class " .. cls .. " lands on a whole hull index",
              menu.class >= 0 and menu.class == math.floor(menu.class),
              "class is " .. tostring(menu.class))
    end
end

-- The three settings that index a table of their own. Every one of these is a
-- number, so the type check they used to get let all of them through.
for _, bad in ipairs({0, -1, 9, 2.5}) do
    if load_with({name = "Probe", volume = bad, music = bad, cap = bad},
                 "volume/music/cap " .. bad) then
        -- apply_settings is what actually indexes them, and it is called by
        -- load_identity above; reaching here at all is most of the point.
        check("settings " .. bad .. " stay whole numbers",
              menu.volume == math.floor(menu.volume)
                  and menu.music == math.floor(menu.music)
                  and menu.cap == math.floor(menu.cap),
              string.format("%s/%s/%s", tostring(menu.volume),
                            tostring(menu.music), tostring(menu.cap)))
        local ok = pcall(menu.apply_settings)
        check("settings " .. bad .. " can be applied", ok)
    end
end

-- And a good save still arrives intact, so none of the above is being bought
-- by ignoring the file.
if load_with({name = "Keeper", class = 2, volume = 2, music = 2, cap = 2},
             "a save this build wrote") then
    check("the saved hull is kept", menu.class == 2, tostring(menu.class))
    check("the saved volume is kept", menu.volume == 2, tostring(menu.volume))
    check("the saved name is kept", menu.name == "Keeper", menu.name)
end

-- The first-zone help offer is part of the saved pilot. A missing key is a
-- pilot who has not answered it, while a dismissal survives the next load.
if load_with({name = "New Pilot"}, "a pilot with no help answer") then
    check("a missing help answer needs the offer", menu.needs_help_prompt())
end
if load_with({name = "Returning Pilot", help_prompt_seen = true},
             "a pilot who dismissed help") then
    check("a saved dismissal suppresses the offer", not menu.needs_help_prompt())
end
last_saved = nil
menu.help_prompt_seen = false
menu.dismiss_help_prompt()
check("dismissing the offer saves it", last_saved and last_saved.help_prompt_seen)

-- The turning camera is a saved answer too, and the only one whose wrong value
-- is a whole different game rather than a wrong volume. It is off unless a save
-- says otherwise, and only a save that says exactly true counts: this key is
-- new, so the builds that come after are the ones that have to survive a file
-- where it means something else.
if load_with({name = "Fresh Pilot"}, "a pilot who never answered ship up") then
    check("a missing answer leaves the world holding still", menu.shipup == false)
end
if load_with({name = "Phone Pilot", ship_up = true}, "a pilot who turned it on") then
    check("a saved yes turns the world", menu.shipup == true)
end
for _, bad in ipairs({1, 0, "yes", {}}) do
    if load_with({name = "Odd Pilot", ship_up = bad},
                 "ship_up " .. type(bad)) then
        check("ship_up " .. type(bad) .. " is not a yes", menu.shipup == false,
              tostring(menu.shipup))
    end
end
-- Offered on glass and nowhere else. A desktop that grew the row would be a
-- desktop offering to change a camera the arena will not turn for it.
local function settings_rows()
    menu.open = true
    menu.stack = {"root", "settings"}
    local v = menu.view()
    menu.open = false
    return v.rows
end

local function row_at(label)
    for i, r in ipairs(settings_rows()) do
        if r.label == label then return i, r end
    end
    return nil
end

menu.touching = false
check("a keyboard is not offered the turning camera", row_at("ship up") == nil)
menu.touching = true
local at = row_at("ship up")
check("a touchscreen is", at ~= nil, tostring(at))

-- And the row works the way a thumb works it: through the same click the
-- interface sends, rather than by calling the action behind it.
if at then
    menu.shipup = false
    last_saved = nil
    menu.open = true
    menu.stack = {"root", "settings"}
    menu.click(at)
    check("pressing the row turns the world", menu.shipup == true)
    check("and saves that", last_saved and last_saved.ship_up == true)
    -- Read off the drawn row rather than off the setting, because the detail
    -- is the only thing on screen that says which way round it now is. `view`
    -- has already resolved it to a string by here.
    local _, r = row_at("ship up")
    check("the row says what it did", r and r.detail == "the world turns",
          r and tostring(r.detail))

    last_saved = nil
    menu.open = true
    menu.stack = {"root", "settings"}
    menu.click(at)
    check("pressing it again holds the world still", menu.shipup == false)
    check("and saves that too", last_saved and last_saved.ship_up == false)
    menu.open = false
end

if fails > 0 then
    print(fails .. " failed")
    os.exit(1)
end
print("all ok")
