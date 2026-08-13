-- The browser bridge is plain Lua and can be checked with small stand-ins for
-- the page, UI, and menu.

package.path = "client/?.lua;" .. package.path

local browser = require("arena.browser")

local calls = {}
local page = {}
function page.run(script)
    calls[#calls + 1] = script
    if string.find(script, "vwPointerOut", 1, true) then return "0" end
    if string.find(script, "vwAskGo", 1, true) then return "a" end
    return ""
end

local cursor = nil
local ui = {link_dom = "https://vectorwake.net", ask_dom = "name"}
function ui.cursor(x, y, alpha) cursor = {x, y, alpha} end
function ui.finish() ui.finished = (ui.finished or 0) + 1 end

local menu = {ask = {keys = {"yes", "no"}}}
function menu.click_answer(i)
    menu.answer = i
    return "join", true
end

local sounds = {}
local sfx = {}
function sfx.ui(name) sounds[#sounds + 1] = name end

local applied = nil
local function apply(self, action) applied = {self, action} end

local state = {cursor_x = 40, cursor_y = 15, cursor_idle = 0}
browser.finish(state, 0.1, 100, page, {used = false}, ui, menu, sfx, apply)

assert(cursor and cursor[1] == 40 and cursor[2] == 85)
assert(cursor[3] == 1)
assert(ui.finished == 1)
assert(menu.dom == true and menu.answer == 1)
assert(sounds[1] == "ui_go")
assert(applied and applied[1] == state and applied[2] == "join")
assert(state.handed_over == true)

local joined = table.concat(calls, "\n")
assert(string.find(joined, "vwLink", 1, true))
assert(string.find(joined, "vwAsk", 1, true))
assert(string.find(joined, "vwReady", 1, true))

print("browser frame tests pass")
