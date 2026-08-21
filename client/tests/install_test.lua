-- The row that puts this on a home screen.
--
--     lua5.1 client/tests/install_test.lua
--
-- Two platforms and two different rows, and the difference is not a choice we
-- made: Chrome hands the page the install and waits to be asked, so there the
-- row is one tap. Safari has no such call and every browser on an iPhone is
-- Safari underneath, so there the row can only say where the button is.
--
-- None of it exists on a desktop, or in an app that is already installed, and
-- a row offering to install the thing you are running inside is the failure
-- worth guarding: the page answers that question and this checks we believe
-- the answer.

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

-- The world the menu talks to, as little of it as it asks for.
package.loaded["arena.account"] = {
    status = function() return "flying as a guest" end,
    key = "", name = "", claim = function() end, aim = function() end,
    claimed = true, base = "https://meta", link_code = "",
    redeem_key = function() end, link = function() end,
}
package.loaded["arena.net"] = {
    teams = {}, my_team = 0, may_found = false,
    my_team_name = function() return "" end,
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
package.loaded["arena.sfx"] = {ui = function() end,
                               master_gain = function() end,
                               music_gain = function() end}
_G.sys = {get_config_string = function(_, d) return d end,
          get_config_int = function(_, d) return d end,
          get_save_file = function() return "/tmp/vw-test-save" end,
          load = function() return {} end, save = function() return true end,
          get_sys_info = function() return {system_name = "Linux"} end}
_G.sound = setmetatable({}, {__index = function() return function() end end})
_G.hash = function(s) return s end

-- The page, answering the one question this asks it. `said` is what the
-- browser would report; `ran` is what we asked the browser to do.
local said, ran = "", {}
_G.html5 = {run = function(js)
    ran[#ran + 1] = js
    if string.find(js, "vwInstallState", 1, true) then return said end
    return ""
end}

local menu = require("arena.menu")
local install = require("arena.install")

-- Straight to the page it lives on, and past the cache each time, since the
-- answer is held for a second of real time and none passes in here.
local function settings(state)
    said = state
    install.tick(9)
    menu.open = true
    menu.stack = {"root", "settings"}
    menu.sel = {}
    return menu.view()
end

local function row_of(v, label)
    for _, r in ipairs(v.rows) do
        if string.lower(r.label) == label then return r end
    end
    return nil
end

check("nothing to add on a machine with no home screen",
      row_of(settings(""), "add to home screen") == nil)

local tap = row_of(settings("tap"), "add to home screen")
check("a browser that will install offers one tap", tap ~= nil)
check("and says so", tap and string.lower(tap.detail) == "one tap",
      tap and tostring(tap.detail))

local share = row_of(settings("share"), "add to home screen")
check("a browser that will not still offers the row", share ~= nil)
check("and says it is going to explain rather than do",
      share and string.lower(share.detail) == "how to",
      share and tostring(share.detail))

-- The row is the last of the settings either way, under the things that are
-- settings and above the two that are destinations.
local function index_of(v, want)
    for i, r in ipairs(v.rows) do
        if string.lower(r.label) == want then return i end
    end
    return nil
end
local v = settings("tap")
local install_at = index_of(v, "add to home screen")
check("it goes under the settings rather than among them",
      install_at ~= nil and install_at == (index_of(v, "controls") or 0) - 1,
      tostring(install_at) .. " of " .. #v.rows)

-- Pressing it. On a browser that will install, this asks it to and says
-- nothing; on one that will not, the only useful thing is the sentence.
local v2 = settings("tap")
ran = {}
menu.click_stage(index_of(v2, "add to home screen"))
local asked = false
for _, js in ipairs(ran) do
    if string.find(js, "vwInstall &&", 1, true) then asked = true end
end
check("one tap asks the browser for the install", asked,
      table.concat(ran, " | "))
check("and raises no card, because the browser is raising one",
      menu.ask == nil)

local v3 = settings("share")
menu.click_stage(index_of(v3, "add to home screen"))
check("the other one says where the button is", menu.ask ~= nil
      and string.find(menu.ask.head, "Add to Home Screen", 1, true) ~= nil,
      menu.ask and menu.ask.head or "no card")
check("with one way out of it", menu.ask and #menu.ask.keys == 1)

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
