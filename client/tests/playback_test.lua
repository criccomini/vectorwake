-- A match link replays the arena's own snapshots and input frames.

package.path = "client/?.lua;" .. package.path

local fails = 0
local function check(name, ok, detail)
    if ok then
        print("ok   " .. name)
    else
        fails = fails + 1
        print("FAIL " .. name .. (detail and (": " .. detail) or ""))
    end
end

local playback = require("arena.playback")
local decoded, why = playback.decode("AP8Q")
check("URL-safe base64 decodes binary bytes",
      decoded == string.char(0, 255, 16), why)
check("bad replay text is refused", playback.decode("a=") == nil)

local snapshots, stepped, mortal = 0, nil, nil
local sim = {
    init = function() end,
    apply_map = function(value) return value == "map" and 0 or -1 end,
    apply_settings = function(value) return value == "rules" and 0 or -1 end,
    apply_snapshot = function(value)
        if value ~= "snap" then return -1 end
        snapshots = snapshots + 1
        return 0
    end,
    ship_count = function() return 2 end,
    ship_active = function() return 1 end,
    ship_team = function(ship) return ship end,
    set_mortal = function(value) mortal = value end,
    step = function(inputs) stepped = inputs end,
}
local net = {map_epoch = 4, settings_epoch = 9, stats = {}}
local payload = {
    zone = "melee",
    match = {
        id = 42, room = 3, map = "drydock",
        teams = {"Blue", "Orange"}, score = {7, 5},
        pilots = {
            {ship = 0, name = "Chord", bot = false, team = 0,
             kills = 7, deaths = 2, assists = 1, points = 12},
            {ship = 1, name = "Rival", bot = true, team = 1,
             kills = 5, deaths = 7, assists = 0, points = 3},
        },
        replay = {
            map = "bWFw", settings = "cnVsZXM",
            segments = {{snapshot = "c25hcA", frames = "AgABAAECAA", ticks = 1}},
        },
    },
}

local state, load_why = playback.load(payload, sim, net)
check("a complete replay loads", state ~= nil, load_why)
check("the replay exposes its score and roster",
      net.match.score[0] == 7 and net.match.score[1] == 5
      and net.pilots[0].name == "Chord" and net.pilots[1].ai == true)
check("the human pilot is the first camera subject",
      net.subject == 0 and net.want == 0 and net.watching == true)
check("map and rules invalidate the renderer caches",
      net.map_epoch == 5 and net.settings_epoch == 10 and mortal == 255)

check("the recorded frame advances", playback.step(state, sim))
check("the original buttons reach the original seats",
      stepped[0] == 1 and stepped[1] == 2)
check("the film loops from its checkpoint", playback.step(state, sim)
      and snapshots == 2)

if fails > 0 then os.exit(1) end
print("all good")
