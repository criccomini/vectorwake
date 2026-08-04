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
-- Music alone is four fifths of the kit's bytes, and moving it would mean
-- rewriting the retry loop below for no audible gain.
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

    print(string.format("SOUND: %d sounds, %d KB, %d ms, %d direct",
                        n, math.floor(bytes / 1024 + 0.5),
                        math.floor((os.clock() - t0) * 1000 + 0.5), quick))
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
