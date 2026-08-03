-- Sound.
--
-- Every sound is synthesised on the player's machine at boot, by the C in
-- client/ext/simcore/src/sfx.c. Nothing here was recorded, sampled or sourced,
-- which is the rule in docs/design/identity.md, and no audio ships in the
-- page: what is in client/sounds/ is fifteen wav files of silence, which exist
-- only to give the sound components something to point at until M.init
-- replaces them.
--
-- The job of this module is restraint. A nine-ship arena fires several
-- hundred bolts a minute, and a client that played all of them at full gain
-- would be unlistenable inside ten seconds. So: distance attenuation, stereo
-- placement, a small pitch spread so repeats do not phase into a machine gun,
-- and a hard per-frame budget per sound.

local M = {}

local RANGE = 760          -- world pixels beyond which a sound is inaudible
local lx, ly = 0, 0

-- How many of each may start in a single frame. A firefight is meant to sound
-- busy, not additive.
local BUDGET = {
    gun = 3, hit = 3, bounce = 2, blast = 2, death = 2, bomb = 2,
}
local DEFAULT_BUDGET = 1

local spent = {}
local seed = 991
local function rnd()
    seed = (seed * 1103515245 + 12345) % 2147483648
    return seed / 2147483648
end

-- Render the kit and hand it to the engine, once, before anything can play.
--
-- Called from the script that owns the sound components, because `#gun`
-- resolves against whoever is asking and a sound component belongs to a game
-- object rather than to this module.
--
-- The whole kit costs about a fifth of a second of arithmetic on a desktop,
-- seven eighths of it the soundtrack, and it is spent here rather than spread
-- over later frames because here is behind the menu the client opens on: a
-- pause before the games list appears is invisible in a way that a pause
-- during a firefight is not.
--
-- A failure is printed and survived. Silence is the failure mode either way,
-- and a client with no audio has to say so somewhere: nothing else about it
-- looks different from a player who turned the volume down.
function M.init()
    local t0 = os.clock()
    local n, bytes = 0, 0
    for _, name in ipairs(vwsfx.names()) do
        local wav = vwsfx.render(name)
        if not wav then
            print("SOUND: no sound named '" .. name .. "'")
        else
            local ok, err = pcall(function()
                resource.set_sound(go.get("#" .. name, "sound"), wav)
            end)
            if ok then
                n = n + 1
                bytes = bytes + #wav
            else
                print("SOUND: cannot install '" .. name .. "': " .. tostring(err))
            end
        end
    end
    -- One line, kept. A browser is not a machine anybody can attach a debugger
    -- to, and this is the difference between "the audio is generated" and
    -- knowing it was, on the machine that is quiet.
    print(string.format("SOUND: %d sounds, %d KB, %d ms",
                        n, math.floor(bytes / 1024 + 0.5),
                        math.floor((os.clock() - t0) * 1000 + 0.5)))
end

function M.listener(x, y)
    lx, ly = x, y
end

-- Called once per frame, before events are drained.
function M.frame()
    for k in pairs(spent) do spent[k] = nil end
end

-- A world sound. Quiet things far away are dropped outright rather than
-- played at a gain nobody can hear, which is what keeps the voice count down
-- in a busy arena.
function M.play(name, x, y)
    local n = (spent[name] or 0) + 1
    if n > (BUDGET[name] or DEFAULT_BUDGET) then return end
    spent[name] = n

    local gain, pan = 1, 0
    if x then
        local dx, dy = x - lx, y - ly
        local d = math.sqrt(dx * dx + dy * dy)
        if d >= RANGE then return end
        local k = 1 - d / RANGE
        gain = k * k
        if gain < 0.035 then return end
        pan = dx / (RANGE * 0.55)
        if pan > 1 then pan = 1 elseif pan < -1 then pan = -1 end
    end

    M.fire(name, {
        gain = gain,
        pan = pan,
        speed = 0.93 + rnd() * 0.14,
    })
end

-- Interface sounds are not in the world and are never attenuated.
function M.ui(name)
    M.fire(name, {gain = 1, pan = 0, speed = 1})
end

-- A sound with a duration rather than an instant: thrust is held, so it is a
-- looping component switched on and off rather than an event replayed.
--
-- Edges only. `sound.play` on a looping component does not restart it, it
-- starts a second voice, so calling it every frame thrust is held stacks
-- sixty of them a second until the mixer runs out.
local held = {}
function M.loop(name, on)
    on = on and true or false
    if on == (held[name] or false) then return end
    held[name] = on
    if on then
        M.fire(name, {gain = 1, pan = 0, speed = 1})
    else
        pcall(sound.stop, "#" .. name)
    end
end

-- The soundtrack, which is a loop like thrust but wanted the moment there is
-- anything to hear rather than on an edge the game computes.
--
-- Asked rather than told: a browser makes no sound at all until the page has
-- been interacted with, so the first attempt is often refused and nothing
-- says so. Checking whether it is actually running and starting it again if
-- not is what makes that self-healing, and it costs one call a keypress.
local music = {want = false, settled = false, wait = 0, tries = 0}

function M.music(on)
    music.want = on and true or false
    music.settled = false
    music.wait = 0
    music.tries = 0
    if not music.want then pcall(sound.stop, "#music") end
end

-- Once a frame, and the reason the soundtrack is asked for rather than told.
--
-- Two gates sit between wanting music and hearing it. A browser makes no
-- sound at all until the page has been interacted with, and Defold's audio
-- device does not wake until something has actually played -- so the first
-- request is accepted, returns success, and is silently dropped. Measured:
-- asking once at the first keypress left the track silent forever, and firing
-- the guns was what let it in.
--
-- So this asks again every couple of seconds until the engine agrees it is
-- running, and then stops asking. Stopping before each retry is what makes
-- that safe: a second voice of a nineteen second loop playing against itself
-- is the worst sound this game could make. The attempt count is a backstop
-- for the case where `is_playing` is wrong about a component -- a bounded
-- number of restarts beats an endless one.
function M.music_tick(dt)
    if not music.want or music.settled then return end
    local ok, playing = pcall(sound.is_playing, "#music")
    if ok and playing then
        music.settled = true
        return
    end
    if music.tries >= 12 then
        music.settled = true
        return
    end
    music.wait = music.wait - (dt or 0)
    if music.wait > 0 then return end
    music.wait = 2.0
    music.tries = music.tries + 1
    pcall(sound.stop, "#music")
    M.fire("music", {gain = 1, pan = 0, speed = 1})
end

-- One place where a sound actually starts.
--
-- Guarded, because a sound component that failed to load must not take the
-- frame loop with it -- but reported, once, because a client that has gone
-- silent looks exactly like a client with the volume down and nothing in the
-- log would ever say which. Swallowing this is how audio stays broken.
local complained = false
function M.fire(name, opts)
    local ok, err = pcall(sound.play, "#" .. name, opts)
    if ok or complained then return end
    complained = true
    print("SOUND: cannot play '" .. name .. "': " .. tostring(err))
end

return M
