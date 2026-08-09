-- Sound.
--
-- Every sound is synthesised on the player's machine at boot, by the C in
-- client/ext/simcore/src/sfx.c. Nothing here was recorded, sampled or sourced,
-- which is the rule in docs/design/identity.md, and no audio ships in the
-- page: what is in client/sounds/ is a wav file of silence per sound, which
-- exists only to give the sound components something to point at until M.init
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

-- The highest variant each family of sounds has, learned from the kit rather
-- than written down here, so adding a rung to sfx.c is the only edit it takes.
local top = {}

-- --- the browser's own audio graph ---------------------------------------
--
-- One-shots do not go through the engine's mixer on the web, because that
-- mixer is why they arrive late.
--
-- Defold's HTML5 sound device mixes into chunks and hands each to Web Audio
-- scheduled at the end of the last one, keeping four of them pending. That
-- queue is the engine's insurance against a slow frame, and it is also the
-- delay on every sound: measured on the shipped page, 43 to 75 ms of already
-- mixed audio waiting to play, on top of whatever the browser's own output
-- costs. A gun fired now joins the back of it.
--
-- The queue depth in seconds *is* the stall margin, so no setting shortens
-- one without shortening the other. `sample_frame_count` was measured at 768
-- and 512: both cut the delay and both crackled on a machine at 26 fps, which
-- is a frame cap this menu offers. Threads do not help either, and were
-- measured making it worse, because Web Audio only exists on the main thread
-- and a sound thread's calls are proxied back to it anyway.
--
-- So the fix is not to shorten the queue but to stand beside it. A one-shot
-- becomes an AudioBufferSourceNode started at once, which the browser renders
-- on its own audio thread: 2.7 ms out rather than 45. The engine's own
-- context is reused rather than a second one made, so the autoplay gate, the
-- gesture unlock in tools/single_file.py, and the iOS audio-session fix all
-- keep applying with nothing to keep in step.
--
-- Held sounds stay on the mixer. A queue is only late at the start, and the
-- start of a rumble that runs for minutes is not a thing anybody can time.
-- Music alone is four fifths of the kit's bytes, so moving it would be work
-- for no audible gain.
local WEB_AUDIO_JS = [[(function () {
  var sh = window._dmJSDeviceShared;
  if (!sh || !sh.audioCtx) return "0";
  var ctx = sh.audioCtx;
  var A = window.vwA = {ctx: ctx, buf: {}, pend: 0, bad: 0, played: 0,
                        out: ctx.createGain()};
  A.out.gain.value = 1;
  A.out.connect(ctx.destination);
  A.load = function (name, b64, want) {
    var bin;
    try { bin = atob(b64); } catch (e) { A.bad++; return "0"; }
    if (bin.length !== want) { A.bad++; return "0"; }
    var by = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) by[i] = bin.charCodeAt(i);
    A.pend++;
    ctx.decodeAudioData(by.buffer,
      function (b) { A.buf[name] = b; A.pend--; },
      function () { A.bad++; A.pend--; });
    return "1";
  };
  A.p = function (name, gain, pan, speed) {
    var b = A.buf[name];
    if (!b) return "0";
    var s = ctx.createBufferSource();
    s.buffer = b;
    s.playbackRate.value = speed;
    var g = ctx.createGain();
    g.gain.value = gain;
    s.connect(g);
    var tail = g;
    if (ctx.createStereoPanner) {
      var p = ctx.createStereoPanner();
      p.pan.value = pan;
      g.connect(p);
      tail = p;
    }
    tail.connect(A.out);
    s.start();
    A.played++;
    return "1";
  };
  A.master = function (v) { A.out.gain.value = v; return "1"; };
  return "1";
})()]]

-- Whether the fast path is up, and what each sound is worth once it is.
--
-- The gain is read off the sound component rather than repeated here: the
-- engine multiplies a played gain by its component's, so a bomb at 0.55 and a
-- gun at 0.30 are the mix, and a second copy of those numbers is a mix that
-- drifts. A sound whose gain cannot be read stays on the mixer, because
-- guessing 1.0 is not a fallback, it is a bomb three times too loud.
local fast = false
local fast_gain = {}
-- Remembered rather than only forwarded, because the menu applies the saved
-- volume during its own load and nothing guarantees that happens after this
-- module is up. Applied again once the graph exists, so the order of the two
-- cannot matter. Getting it wrong is every effect at full volume against a
-- soundtrack at the setting, which is a loud way to find out.
local master = 1

-- --- eight tracks, one at a time ------------------------------------------
--
-- There are eight of them and the game plays each for three minutes before
-- crossfading into the next, which is long enough that nobody hears a rotation
-- as a change of subject and short enough that a long session is not one loop
-- forty times over.
--
-- Where a session starts is random, so two people in the same arena are not
-- listening in step and a player who quits after ten minutes has not heard
-- only the first three.
--
-- Two components hold the music, and the tracks alternate between them. That
-- is what a crossfade costs: a component holds one buffer, so two of them have
-- to be audible at once for one to give way to the other. Two is also where it
-- stops. Eight would be eight buffers of about a megabyte each, six of them
-- silent at any moment, which is most of a page's worth of memory to save a
-- copy.
local SLOT = {"music_a", "music_b"}
local live = 1                  -- which slot is playing
M.track = 1
local ROTATE = 180              -- seconds a track holds the floor

-- Two seconds, which is a crossfade and not a blend.
--
-- These eight are in eight different keys at eight different tempos, so an
-- overlap is a clash however it is shaped and the only question is how long it
-- lasts. Two seconds is long enough that neither track is cut off and short
-- enough that the clash reads as a turn rather than as a passage.
local FADE = 2.0
local rotate_left = ROTATE
local fading = nil              -- seconds into the fade, or nil

-- The next track, built while this one is still playing.
--
-- It has to be built ahead because building is not free: a track is about an
-- eighth of a second of arithmetic, and spending that on the frame a rotation
-- falls due is a frozen frame in the middle of a fight. sfx.c cuts the work
-- into forty-two steps of at most eight milliseconds, and the loop below
-- spends one step at a time, only on frames that had room for it.
--
-- Eight milliseconds is still half a frame, so `dt` decides. A frame that
-- already ran long does not get asked to carry a step as well, and nothing is
-- lost by skipping it: an eighth of a second of work has three minutes to
-- find room in.
local build = {track = nil, wav = nil, wait = 0}
local BUILD_EVERY = 0.25        -- seconds between steps
local BUILD_ROOM = 0.020        -- a frame longer than this carries nothing

-- Put a wav into a slot's component.
local function fill(slot, wav)
    local ok, err = pcall(function()
        resource.set_sound(go.get("#" .. SLOT[slot], "sound"), wav)
    end)
    if not ok then
        print("SOUND: cannot install the soundtrack: " .. tostring(err))
    end
    return ok
end

-- Put a track into the live slot, building it here and now.
--
-- Used at boot, where a tenth of a second behind the menu is invisible, and as
-- the fallback whenever a rotation comes due with nothing built: better a
-- hitch than the music stopping. Returns how many bytes went in, or nil.
function M.music_install(i)
    if i then M.track = i end
    if not vwsfx.music_begin(M.track) then
        print("SOUND: no track " .. tostring(M.track))
        return nil
    end
    while not vwsfx.music_step() do end
    local wav = vwsfx.music_take()
    if not wav then
        print("SOUND: track " .. M.track .. " did not build")
        return nil
    end
    if not fill(live, wav) then return nil end
    return #wav
end

-- Start somewhere different every session. os.time has a resolution of a
-- second, which is plenty when the question is which of eight.
local function pick_first()
    local t = os.time()
    if type(t) ~= "number" then return 1 end
    return math.floor(t) % vwsfx.music_count() + 1
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
    local n, bytes, quick = 0, 0, 0
    M.track = pick_first()

    -- The browser path is offered, not assumed. Every step of standing it up
    -- can fail on some engine or some browser, and each failure simply leaves
    -- that sound where it already worked.
    if html5 then
        local ok, r = pcall(html5.run, WEB_AUDIO_JS)
        fast = ok and r == "1"
        if not fast then print("SOUND: no browser audio path, using the mixer") end
    end

    for _, name in ipairs(vwsfx.names()) do
        local fam, idx = name:match("^(.-)(%d+)$")
        if fam then
            idx = tonumber(idx)
            if idx > (top[fam] or -1) then top[fam] = idx end
        end
        -- The two soundtrack slots are the components the kit does not render
        -- from a name, because which of the eight tracks is in one changes
        -- while the game runs. M.music_install fills the live one, here and
        -- at every rotation after; the other stays empty until the first
        -- crossfade needs it.
        local slot = name:match("^music_")
        local wav = not slot and vwsfx.render(name) or nil
        if slot then
            if name == "music_a" then
                local built = M.music_install(nil)
                if built then n = n + 1 bytes = bytes + built end
            end
        elseif not wav then
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
            -- And again, for the browser, if this is one the browser takes.
            -- The decoded length is checked on the far side: a base64 tail
            -- encoded wrong decodes to something shorter and still plays,
            -- ending in a click nobody would trace back to here.
            if ok and fast and not vwsfx.is_loop(name) then
                local okg, g = pcall(go.get, "#" .. name, "gain")
                local okr, r = pcall(html5.run, string.format(
                    'vwA.load("%s","%s",%d)', name, vwsfx.b64(wav), #wav))
                if okg and okr and r == "1" then
                    fast_gain[name] = g
                    quick = quick + 1
                end
            end
        end
    end
    -- One line, kept. A browser is not a machine anybody can attach a debugger
    -- to, and this is the difference between "the audio is generated" and
    -- knowing it was, on the machine that is quiet.
    -- Whatever the volume already is, now that there is a graph to set it on.
    if fast then M.master_gain(master) end

    print(string.format("SOUND: %d sounds, %d KB, %d ms, %d direct, track %d",
                        n, math.floor(bytes / 1024 + 0.5),
                        math.floor((os.clock() - t0) * 1000 + 0.5), quick,
                        M.track))
end

-- The master volume, which the browser path has to be told about because it
-- is not in the engine's mixer to be told by `sound.set_group_gain`. Called
-- from wherever that is, so the two cannot hold different numbers.
function M.master_gain(v)
    master = v
    if fast then pcall(html5.run, string.format('vwA.master(%.4f)', v)) end
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
--
-- `variant` names one of a family of components, which is how the weapon
-- ladders sound different rung by rung: `gun` plus rung 2 is the component
-- `gun2`. The budget stays keyed on the family, because four rungs of the
-- same gun are still guns and three of them a frame is still the ceiling.
--
-- A rung past the end of a family gets the top of it rather than silence. The
-- simulation's ladder can be longer than the kit is, and a weapon that stops
-- making a sound at rung five would be a strange way to find that out.
function M.play(name, x, y, variant)
    local n = (spent[name] or 0) + 1
    if n > (BUDGET[name] or DEFAULT_BUDGET) then return end
    spent[name] = n

    if variant then
        local hi = top[name]
        if not hi then
            variant = nil
        elseif variant > hi then
            variant = hi
        elseif variant < 0 then
            variant = 0
        end
    end

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

    M.fire(variant and (name .. variant) or name, {
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
-- Wanting it and starting it are separate, because a browser makes no sound
-- until the page has been interacted with, and a track started before that is
-- not held back, it runs silently. So `want` is set at boot and the start
-- waits for the device. See M.music_tick.
local music = {want = false, settled = false}

function M.music(on)
    music.want = on and true or false
    music.settled = false
    if not music.want then
        fading = nil
        for _, name in ipairs(SLOT) do pcall(sound.stop, "#" .. name) end
    end
end

-- Is the browser's audio actually awake?
--
-- A page makes no sound until it has been interacted with, and the engine's
-- device does not queue anything while its context is suspended: it mixes the
-- audio and throws it away, so a track started before the gesture is not
-- waiting, it is running silently and losing its beginning.
--
-- This asks the context directly, which is the only honest answer available.
-- Nil on anything but the web, where there is no gate to wait for.
local function audio_awake()
    if not html5 then return true end
    local ok, r = pcall(html5.run, [[(window._dmJSDeviceShared
        && window._dmJSDeviceShared.audioCtx
        && window._dmJSDeviceShared.audioCtx.state === "running") ? "1" : "0"]])
    return ok and r == "1"
end

-- Once a frame, until the soundtrack is running.
--
-- Started when the audio device is awake rather than at once, and started
-- exactly once. Both halves of that were wrong before, in a way that took
-- reading the engine's own JavaScript to see.
--
-- The old version polled `sound.is_playing` and restarted the track whenever
-- the answer was not yes. There is no `sound.is_playing` in Defold's sound
-- module, so the call raised every frame, the answer was never yes, and the
-- backstop that was meant for a misreported component became the normal path:
-- twelve restarts at two second intervals across the first twenty-three
-- seconds of every session, measured in the shipped build. A player heard the
-- opening bars begin over and over.
--
-- Starting it before the gate is the other half. Audio mixed into a suspended
-- context is discarded rather than held, so the track advances while nobody
-- can hear it, and the first thing a player does hear is the middle of it.
--
-- It also drives the rotation, which is why it keeps being called after the
-- track has started: three minutes on each of the eight, with the next one
-- built quietly in the gaps beforehand.
function M.music_tick(dt)
    if not music.want then return end
    if not music.settled then
        if not audio_awake() then return end
        music.settled = true
        M.fire(SLOT[live], {gain = 1, pan = 0, speed = 1})
        rotate_left = ROTATE
        build.track = M.track % vwsfx.music_count() + 1
        build.wav, build.wait = nil, 0
        vwsfx.music_begin(build.track)
        return
    end

    -- A step at a time, and only on a frame that had room to spare. Nothing
    -- here is urgent: the whole build is a fraction of a second of work with
    -- three minutes to do it in, so a run of busy frames costs nothing but a
    -- later finish.
    if build.track and not build.wav then
        build.wait = build.wait + dt
        if build.wait >= BUILD_EVERY and dt <= BUILD_ROOM then
            build.wait = 0
            if vwsfx.music_step() then build.wav = vwsfx.music_take() or false end
        end
    end

    -- Mid-crossfade: one slot going up, the other coming down.
    --
    -- Sine against cosine rather than a straight ramp either way. Two tracks
    -- have nothing to do with each other, so their power adds rather than
    -- their amplitude, and two straight ramps crossing at a half leave a hole
    -- three decibels deep in the middle of every rotation. Squares of a sine
    -- and a cosine sum to one at every point of the fade, which is the whole
    -- reason for the curve.
    if fading then
        fading = fading + dt
        local x = fading / FADE
        if x >= 1 then
            pcall(sound.stop, "#" .. SLOT[3 - live])
            fading = nil
        else
            local a = x * math.pi / 2
            pcall(sound.set_gain, "#" .. SLOT[live], math.sin(a))
            pcall(sound.set_gain, "#" .. SLOT[3 - live], math.cos(a))
        end
    end

    rotate_left = rotate_left - dt
    if rotate_left > 0 then return end

    -- The rotation falls due. Filling the other slot is a copy rather than a
    -- render, so it is cheap enough to do outright; only a build that never
    -- finished costs anything here, and it costs a hitch rather than a
    -- silence.
    rotate_left = ROTATE
    local next_track = build.track or (M.track % vwsfx.music_count() + 1)
    local into = 3 - live

    if build.wav and fill(into, build.wav) then
        -- Both audible, the new one from nothing. A fade already running is
        -- taken over rather than waited for: three minutes apart, that can
        -- only happen if ROTATE were set shorter than FADE, and a half-faded
        -- track left playing under two others is a worse answer than a
        -- slightly abrupt one.
        if fading then pcall(sound.stop, "#" .. SLOT[3 - live]) end
        M.track = next_track
        live = into
        -- Started at nothing and brought up by the fade below. The gain here
        -- is the one the fade moves; the level the track sits at is the .sound
        -- file's, which the engine multiplies by it.
        M.fire(SLOT[live], {gain = 0, pan = 0, speed = 1})
        fading = 0
    else
        -- Nothing built, so there is nothing to fade into. Build it into the
        -- slot that is already playing and cut, which is what this did before
        -- there were two slots.
        fading = nil
        pcall(sound.stop, "#" .. SLOT[live])
        M.music_install(next_track)
        M.fire(SLOT[live], {gain = 1, pan = 0, speed = 1})
    end

    build.track = M.track % vwsfx.music_count() + 1
    build.wav, build.wait = nil, 0
    vwsfx.music_begin(build.track)
end

-- One place where a sound actually starts.
--
-- Guarded, because a sound component that failed to load must not take the
-- frame loop with it -- but reported, once, because a client that has gone
-- silent looks exactly like a client with the volume down and nothing in the
-- log would ever say which. Swallowing this is how audio stays broken.
-- One place where a sound actually starts, and the fork between the two
-- paths. A one-shot the browser has decoded goes straight to Web Audio; a
-- loop, a sound still decoding, or anything off the web goes to the mixer.
--
-- The fallback is the point rather than a courtesy. `decodeAudioData` is
-- asynchronous, so for the first moments after boot the browser has the bytes
-- and not yet the buffer, and those sounds have to come out somewhere.
local complained = false
function M.fire(name, opts)
    local g = fast and fast_gain[name]
    if g then
        local ok, r = pcall(html5.run, string.format(
            'vwA.p("%s",%.4f,%.4f,%.4f)', name, opts.gain * g, opts.pan,
            opts.speed))
        if ok and r == "1" then return end
    end
    local ok, err = pcall(sound.play, "#" .. name, opts)
    if ok or complained then return end
    complained = true
    print("SOUND: cannot play '" .. name .. "': " .. tostring(err))
end

return M
