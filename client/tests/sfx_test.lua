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
local LOOPS = {}
do
    local f = assert(io.open("client/ext/simcore/src/sfx.c"),
                     "run me from the repository root")
    local src = f:read("*a")
    f:close()
    local list = assert(src:match("const char %*const sfx_names%[%] = {(.-)};"),
                        "sfx_names not found in sfx.c")
    for name in list:gmatch('"([%w_]+)"') do NAMES[#NAMES + 1] = name end
    -- Which of them loop, off the KIT table, so the test cannot hold a
    -- different opinion from the synth about what is a held sound.
    local kit = assert(src:match("static const entry KIT%[%] = {(.-)};"),
                       "KIT not found in sfx.c")
    -- The duration is any expression, not just a literal: the soundtrack's is
    -- computed from the bar count.
    for name, loop in kit:gmatch('{"([%w_]+)",%s*[^,]+,%s*(%d),') do
        LOOPS[name] = loop == "1"
    end
    assert(LOOPS.music and LOOPS.thrust, "the loops did not parse")
end

local played = {}

_G.vwsfx = {
    names = function() return NAMES end,
    -- Enough of a wav header to be a string with a length. Nothing here
    -- decodes it: resource.set_sound is the engine's, and it is stubbed.
    render = function() return string.rep("\0", 44) end,
    b64 = function(s) return string.rep("A", math.ceil(#s / 3) * 4) end,
    is_loop = function(name) return LOOPS[name] end,
}
_G.resource = {set_sound = function() end}
-- The component gain the browser path reads back, so the mix survives the
-- move. A real one is whatever the .sound file says.
local COMPONENT_GAIN = 0.5
_G.go = {get = function(url, prop)
    if prop == "gain" then return COMPONENT_GAIN end
    return url
end}
-- Only what Defold's sound module actually has. There is no sound.is_playing,
-- and a stub that invented one is how the soundtrack came to restart twelve
-- times a session without a test noticing: the code called it, the call raised
-- every frame under pcall, and here it cheerfully returned true.
_G.sound = {
    play = function(url) played[#played + 1] = url end,
    stop = function() end,
    set_group_gain = function() end,
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

for rung = 0, 3 do
    try("blast at rung " .. rung, "#blast" .. rung,
        function() sfx.play("blast", 0, 0, rung) end)
end

-- A family with no variants ignores the rung rather than inventing one.
try("death with a rung", "#death", function() sfx.play("death", 0, 0, 2) end)
try("death with no rung", "#death", function() sfx.play("death", 0, 0) end)

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

-- --- and again on the web, where one-shots leave the mixer ---------------
--
-- The split is the whole point of the browser path: a one-shot goes straight
-- to Web Audio to skip the mixer's queue, a loop stays on the mixer because a
-- queue is only late at the start. Getting it backwards is silent both ways,
-- a loop that never repeats and effects that are still late.
local evals = {}
_G.html5 = {run = function(js) evals[#evals + 1] = js; return "1" end}
package.loaded["arena.sfx"] = nil
local web = require("arena.sfx")
web.init()
web.listener(0, 0)

local function web_try(desc, want_js, want_mixer, fn)
    played, evals = {}, {}
    web.frame()
    fn()
    local js = nil
    for _, e in ipairs(evals) do
        if e:match("^vwA%.p%(") then js = e end
    end
    local got_js = js and js:match('^vwA%.p%("([%w_]+)"') or nil
    local ok = got_js == want_js and (played[1] ~= nil) == want_mixer
    if not ok then fails = fails + 1 end
    print(string.format("%-38s -> %-10s %s", desc,
                        tostring(got_js or played[1]),
                        ok and "ok" or "FAIL"))
    return js
end

local gun_js = web_try("gun goes straight to Web Audio", "gun0", false,
                       function() web.play("gun", 0, 0, 0) end)
web_try("a UI bleep does too", "ui_go", false, function() web.ui("ui_go") end)
web_try("thrust stays on the mixer", nil, true,
        function() web.loop("thrust", true) end)
web_try("and so does the soundtrack", nil, true,
        function() web.fire("music", {gain = 1, pan = 0, speed = 1}) end)

-- The component's own gain has to reach the browser, or the mix that the
-- .sound files carry is lost the moment a sound stops going through them.
if gun_js then
    local g = tonumber(gun_js:match('^vwA%.p%("[%w_]+",([%-%d%.]+)'))
    local want = 1.0 * COMPONENT_GAIN
    local ok = g and math.abs(g - want) < 0.001
    if not ok then fails = fails + 1 end
    print(string.format("%-38s -> %-10s %s", "carries the component gain",
                        tostring(g), ok and "ok" or ("FAIL, wanted " .. want)))
end

-- A sound the browser has not decoded yet must not vanish. decodeAudioData is
-- asynchronous, so this is the first second of every session.
_G.html5.run = function(js)
    if js:match("^vwA%.p%(") then return "0" end     -- not decoded yet
    return "1"
end
played, evals = {}, {}
web.frame()
web.play("gun", 0, 0, 0)
local fell_back = played[1] == "#gun0"
if not fell_back then fails = fails + 1 end
print(string.format("%-38s -> %-10s %s", "falls back while still decoding",
                    tostring(played[1]), fell_back and "ok" or "FAIL"))

-- The soundtrack starts once, and not before the browser's audio is awake.
--
-- Starting it early is not harmless. A suspended context has its mixed audio
-- thrown away rather than held, so the track runs on silently and a player
-- joins it in the middle. Starting it repeatedly is worse, and was the bug:
-- the opening bars began over and over for the first twenty-three seconds.
do
    local awake = false
    local starts = 0
    _G.html5 = {run = function(js)
        if js:match("audioCtx%.state") then return awake and "1" or "0" end
        return "1"
    end}
    package.loaded["arena.sfx"] = nil
    local s = require("arena.sfx")
    s.init()
    local realplay = _G.sound.play
    _G.sound.play = function(url)
        if url == "#music" then starts = starts + 1 end
        return realplay(url)
    end

    s.music(true)
    for _ = 1, 200 do s.music_tick(0.016) end       -- three seconds, still muted
    local quiet = starts
    awake = true
    for _ = 1, 200 do s.music_tick(0.016) end       -- and three more, awake

    local ok = quiet == 0 and starts == 1
    if not ok then fails = fails + 1 end
    print(string.format("%-38s -> %-10s %s",
                        "music waits, then starts once",
                        quiet .. " then " .. starts,
                        ok and "ok" or "FAIL, wanted 0 then 1"))
    _G.sound.play = realplay
end

-- The master volume has to reach the browser graph whichever order the menu
-- and this module come up in. The menu applies the saved volume during its own
-- load, and nothing sequences that against sfx.init.
for _, order in ipairs({"volume first", "init first"}) do
    local set = {}
    _G.html5 = {run = function(js)
        local v = js:match("^vwA%.master%(([%d%.]+)%)")
        if v then set[#set + 1] = tonumber(v) end
        return "1"
    end}
    package.loaded["arena.sfx"] = nil
    local s = require("arena.sfx")
    if order == "volume first" then
        s.master_gain(0.6)
        s.init()
    else
        s.init()
        s.master_gain(0.6)
    end
    local last = set[#set]
    local ok = last == 0.6
    if not ok then fails = fails + 1 end
    print(string.format("%-38s -> %-10s %s", "master gain survives " .. order,
                        tostring(last), ok and "ok" or "FAIL, wanted 0.6"))
end

print(fails == 0 and "ALL PASS" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
