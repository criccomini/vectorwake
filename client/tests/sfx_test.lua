-- Which component a rung ends up playing.
--
--     lua5.1 client/tests/sfx_test.lua
--
-- Run under plain Lua 5.1, which is what HTML5 builds run, with the engine
-- stubbed out. This exists because the path it covers is unreachable from a
-- browser without a server to join: firing a weapon at rung three needs an
-- arena, an opponent and a tech tree climbed, and by then a wrong component id
-- sounds like nothing at all rather than like a failure.
--
-- The kit's names are read out of sfx.c rather than written down here, so a
-- rung added to the C is a rung this test immediately covers.

package.path = "client/?.lua;" .. package.path

local NAMES = {}
do
    local f = assert(io.open("client/ext/simcore/src/sfx.c"),
                     "run me from the repository root")
    local src = f:read("*a")
    f:close()
    local list = assert(src:match("const char %*const sfx_names%[%] = {(.-)};"),
                        "sfx_names not found in sfx.c")
    for name in list:gmatch('"([%w_]+)"') do NAMES[#NAMES + 1] = name end
end

local played = {}

_G.vwsfx = {
    names = function() return NAMES end,
    -- Enough of a wav header to be a string with a length. Nothing here
    -- decodes it: resource.set_sound is the engine's, and it is stubbed.
    render = function() return string.rep("\0", 44) end,
}
_G.resource = {set_sound = function() end}
_G.go = {get = function(url) return url end}
_G.sound = {
    play = function(url) played[#played + 1] = url end,
    stop = function() end,
    is_playing = function() return true end,
}

local sfx = require("arena.sfx")
sfx.init()
sfx.listener(0, 0)

local fails = 0
local function try(desc, want, fn)
    played = {}
    sfx.frame()
    fn()
    local got = played[1]
    if got ~= want then fails = fails + 1 end
    print(string.format("%-38s -> %-10s %s", desc, tostring(got),
                        got == want and "ok" or ("FAIL, wanted " .. tostring(want))))
end

for rung = 0, 3 do
    try("gun at rung " .. rung, "#gun" .. rung,
        function() sfx.play("gun", 0, 0, rung) end)
end
for rung = 0, 3 do
    try("bomb at rung " .. rung, "#bomb" .. rung,
        function() sfx.play("bomb", 0, 0, rung) end)
end

-- A ladder longer than the kit lands on the top rung rather than on silence.
try("gun at rung 7, past the kit", "#gun3",
    function() sfx.play("gun", 0, 0, 7) end)
try("gun at rung -1", "#gun0", function() sfx.play("gun", 0, 0, -1) end)

-- A family with no variants ignores the rung rather than inventing one.
try("blast with a rung", "#blast", function() sfx.play("blast", 0, 0, 2) end)
try("blast with no rung", "#blast", function() sfx.play("blast", 0, 0) end)

-- Distance still culls, whatever the rung.
try("gun at 900px, out of range", nil,
    function() sfx.play("gun", 900, 0, 2) end)

-- The budget is per family and not per rung: four rungs fired in one frame are
-- still three guns, or a pilot at the top of the ladder would be four times as
-- loud as one at the bottom.
played = {}
sfx.frame()
for rung = 0, 3 do sfx.play("gun", 0, 0, rung) end
if #played ~= 3 then fails = fails + 1 end
print(string.format("%-38s -> %-10s %s", "four rungs in one frame", #played,
                    #played == 3 and "ok" or "FAIL, wanted 3"))

-- Every sound the kit renders needs somewhere to go. A name in sfx.c with no
-- component behind it installs nothing and plays nothing, and the only symptom
-- is one sound missing from a game nobody is listening to that closely.
local collection
do
    local f = assert(io.open("client/main/main.collection"))
    collection = f:read("*a")
    f:close()
end
local unwired = 0
for _, name in ipairs(NAMES) do
    local snd = io.open("client/sounds/" .. name .. ".sound")
    local wired = collection:find("/sounds/" .. name .. ".sound", 1, true)
    if snd then snd:close() end
    if not snd or not wired then
        unwired = unwired + 1
        print(string.format("%-38s    %s", name,
                            not snd and "FAIL, no .sound file"
                                    or "FAIL, not in main.collection"))
    end
end
fails = fails + unwired
print(string.format("%-38s -> %-10s %s", "every sound has a component",
                    #NAMES - unwired .. "/" .. #NAMES,
                    unwired == 0 and "ok" or "FAIL"))

print(fails == 0 and "ALL PASS" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
