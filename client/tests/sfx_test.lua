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
    -- The duration is any expression, not just a literal, and the
    -- soundtrack's is zero: it has a component and no maker, being built a
    -- step at a time rather than rendered from its name.
    for name, loop in kit:gmatch('{"([%w_]+)",%s*[^,]+,%s*(%d),') do
        LOOPS[name] = loop == "1"
    end
    assert(LOOPS.music_a and LOOPS.thrust, "the loops did not parse")
end

local played = {}

-- The soundtrack, stubbed as the step machine sfx.c actually is: begun,
-- stepped until it says it is finished, then taken once.
local TRACKS = 8
local job = {track = nil, left = 0, begun = 0, taken = 0}
_G.vwsfx = {
    names = function() return NAMES end,
    -- Enough of a wav header to be a string with a length. Nothing here
    -- decodes it: resource.set_sound is the engine's, and it is stubbed.
    render = function() return string.rep("\0", 44) end,
    b64 = function(s) return string.rep("A", math.ceil(#s / 3) * 4) end,
    is_loop = function(name) return LOOPS[name] end,
    music_count = function() return TRACKS end,
    music_begin = function(i)
        job.track, job.left = i, 4
        job.begun = job.begun + 1
        return true
    end,
    music_step = function()
        if job.left > 0 then job.left = job.left - 1 end
        return job.left == 0
    end,
    music_take = function()
        if not job.track or job.left > 0 then return nil end
        job.taken = job.taken + 1
        job.track = nil
        return string.rep("\0", 44)
    end,
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
--
-- set_gain is real and is what the crossfade rides on: "set gain on all active
-- playing voices of a sound", which is the one documented way to move the
-- level of something already playing.
local voice = {}
_G.sound = {
    play = function(url, opts)
        played[#played + 1] = url
        voice[url] = (opts and opts.gain) or 1
    end,
    stop = function(url) voice[url] = nil end,
    set_gain = function(url, g) voice[url] = g end,
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

-- --- eight tracks, three minutes each --------------------------------------
--
-- The rotation is the one part of the soundtrack a player cannot check by
-- listening for ten seconds, and the failure it is guarding against is
-- expensive: a build that is not ready when the rotation falls due costs a
-- frozen frame in the middle of a fight, which is the whole reason the build
-- is spread over frames at all.

local function drive(seconds, dt)
    dt = dt or 0.016
    for _ = 1, math.floor(seconds / dt) do sfx.music_tick(dt) end
end

do
    local started = sfx.track
    local ok = started >= 1 and started <= 8
    if not ok then fails = fails + 1 end
    print(string.format("%-38s -> %-10s %s", "a session starts on some track",
                        tostring(started), ok and "ok" or "FAIL"))

    sfx.music(true)
    drive(1)                              -- wakes, starts, and begins a build
    local first = sfx.track
    drive(60)                             -- long before the rotation is due
    local ok2 = sfx.track == first and job.taken >= 1
    if not ok2 then fails = fails + 1 end
    print(string.format("%-38s -> %-10s %s",
                        "the next track is built well ahead",
                        job.taken .. " built", ok2 and "ok" or "FAIL"))

    drive(130)                            -- past three minutes in total
    local ok3 = sfx.track == first % 8 + 1
    if not ok3 then fails = fails + 1 end
    print(string.format("%-38s -> %-10s %s", "and it takes over at three minutes",
                        first .. " then " .. sfx.track, ok3 and "ok" or "FAIL"))

    -- Round and round: eight rotations from anywhere lands back where it
    -- started, which is what makes this a rotation rather than a walk off the
    -- end of the list.
    for _ = 1, 7 do drive(181) end
    local ok4 = sfx.track == first
    if not ok4 then fails = fails + 1 end
    print(string.format("%-38s -> %-10s %s", "eight rotations come back round",
                        tostring(sfx.track), ok4 and "ok" or "FAIL"))
    sfx.music(false)
end

-- A frame that already ran long is not asked to carry a build step as well.
do
    local before = job.begun
    package.loaded["arena.sfx"] = nil
    local s2 = require("arena.sfx")
    s2.init()
    s2.music(true)
    s2.music_tick(0.016)
    local steps_before = job.left
    for _ = 1, 50 do s2.music_tick(0.5) end   -- half-second frames, all busy
    local ok = job.left == steps_before and job.begun > before
    if not ok then fails = fails + 1 end
    print(string.format("%-38s -> %-10s %s", "a busy frame carries no build",
                        job.left .. " steps left", ok and "ok" or "FAIL"))
    s2.music(false)
end

-- --- the crossfade --------------------------------------------------------
--
-- Two tracks are audible while one gives way to the other, and the thing that
-- can go wrong quietly is the shape of it. Two straight ramps crossing at a
-- half leave a hole three decibels deep in the middle of every rotation, which
-- a player would hear as the music ducking at the change and would have no way
-- to describe.

do
    package.loaded["arena.sfx"] = nil
    local s3 = require("arena.sfx")
    local function run(seconds)
        for _ = 1, math.floor(seconds / 0.016) do s3.music_tick(0.016) end
    end
    s3.init()
    s3.music(true)
    run(1)
    local from = "#music_a"
    local ok_one = voice[from] == 1 and voice["#music_b"] == nil
    if not ok_one then fails = fails + 1 end
    print(string.format("%-38s -> %-10s %s", "one slot plays to begin with",
                        tostring(voice[from]), ok_one and "ok" or "FAIL"))

    run(179)                              -- up to the rotation
    local worst, samples = 0, 0
    for _ = 1, 60 do                        -- a second into the fade
        s3.music_tick(0.016)
        local a, b = voice["#music_a"], voice["#music_b"]
        if a and b then
            samples = samples + 1
            local power = a * a + b * b
            if math.abs(power - 1) > worst then worst = math.abs(power - 1) end
        end
    end
    local ok_both = samples > 30
    if not ok_both then fails = fails + 1 end
    print(string.format("%-38s -> %-10s %s", "both are audible through it",
                        samples .. " frames", ok_both and "ok" or "FAIL"))

    -- Equal power: the squares sum to one at every point, so nothing dips.
    local ok_power = worst < 0.001
    if not ok_power then fails = fails + 1 end
    print(string.format("%-38s -> %-10s %s", "and the level never dips",
                        string.format("%.4f off", worst),
                        ok_power and "ok" or "FAIL"))

    run(2)                                -- past the end of the fade
    local ok_done = voice["#music_a"] == nil and voice["#music_b"] ~= nil
    if not ok_done then fails = fails + 1 end
    print(string.format("%-38s -> %-10s %s", "and the old one is let go",
                        tostring(voice["#music_a"]),
                        ok_done and "ok" or "FAIL"))

    -- And back, so the slots alternate rather than one of them being the
    -- soundtrack and the other a place tracks go to fade out.
    run(182)
    local ok_swap = voice["#music_a"] ~= nil and voice["#music_b"] == nil
    if not ok_swap then fails = fails + 1 end
    print(string.format("%-38s -> %-10s %s", "the next rotation goes back",
                        tostring(voice["#music_a"]),
                        ok_swap and "ok" or "FAIL"))
    s3.music(false)
end

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
        function() web.fire("music_a", {gain = 1, pan = 0, speed = 1}) end)

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
    _G.sound.play = function(url, opts)
        if url:match("^#music_") then starts = starts + 1 end
        return realplay(url, opts)
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
