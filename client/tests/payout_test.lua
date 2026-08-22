-- What a kill paid, floating off the wreck.
--
--     lua5.1 client/tests/payout_test.lua
--
-- The number is raised by `arena.script` when the zone says you took somebody
-- and drawn by `ui.lua` for the second and a bit afterwards, rising and going
-- out. None of that is visible in a screenshot of one frame, and all of it is
-- arithmetic on a clock, so it is checked here against the real `M.hud` with
-- a stubbed engine: that a number appears where the hull died, that it climbs,
-- that it fades, and that it leaves rather than sitting on screen forever.

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

-- --- the engine, as much of it as ui.lua touches ---------------------------

local layer = {n = 0}
local function noop(self) self.n = self.n + 1 end
for _, name in ipairs({"arc", "disc", "flush", "frame", "outline", "quad",
                       "rect", "reset", "ring", "seg", "seg_fade",
                       "seg_flat", "skirt",
                       "tri", "tri_fade"}) do
    layer[name] = noop
end

local room = {count = 2, teams = {[0] = 1, 1}}
local sim = {
    ship_count = function() return room.count end,
    ship_x = function(i) return 100 + i * 180 end,
    ship_y = function(i) return 100 + i * 120 end,
    ship_heading = function() return 0 end,
    ship_alive = function() return 1 end,
    ship_team = function(i) return room.teams[i] or 0 end,
    ship_class = function() return 0 end,
    ship_energy = function() return 100 end,
    ship_max_energy = function() return 100 end,
    ship_kills = function() return 0 end,
    ship_deaths = function() return 0 end,
    ship_assists = function() return 0 end,
    ship_points = function() return 0 end,
    -- Nobody carries a bounty here, so the only number on the field is the
    -- one under test and a stray match cannot be a nameplate's.
    ship_bounty = function() return 0 end,
    ship_up = function() return 0 end,
    ship_level = function() return 0 end,
    ship_charge = function() return 0 end,
    ship_mod = function() return 0 end,
    ship_multi_off = function() return 0 end,
    charge_max = function() return 3 end,
    has_trigger = function() return true end,
    trigger_rate = function() return 1 end,
    tick = function() return 4242 end,
    weapon_count = function() return 0 end,
    prize_count = function() return 0 end,
    prize_at = function() return 0, 0, 0 end,
    flag_count = function() return 0 end,
    flag_at = function() return 0, 0, 255 end,
    map_coarse = function() return nil end,
    BTN_FIRE = 1,
}
_G.sim = sim

package.loaded["arena.state"] = {text = {}, n = 0, version = 0}
package.loaded["arena.touch"] = {
    layout = function() return {charge = {}} end,
    used = false,
}
package.loaded["arena.world"] = {
    build_overview = function() end,
    forget_overview = function() end,
    overview = function() return {grid = 0, rects = {}} end,
    radar_tiles = {160, 160},
    radar_safe = {},
    radar_doors = {},
}

local ui = require("arena.ui")
local pal = require("arena.palette")

-- --- the harness -----------------------------------------------------------

local W, H = 1280, 800
-- The camera sits on ship 0, and half_w is half the width, so the world and
-- the screen are one to one and a wreck at the camera lands dead center.
local CAM_X, CAM_Y = 100, 100

local function frame(now)
    package.loaded["arena.state"].n = 0
    ui.begin(layer, W, H, 1, false, now)
    ui.hud({
        me = 0,
        class_names = {"Apex", "Wedge", "Chord", "Anvil", "Facet", "Cipher",
                       "Lattice"},
        menu_open = false,
        pilots = {[0] = {name = "you", label = "human"},
                  [1] = {name = "someone", label = "human"}},
        teams = {}, feed = {}, hurt = 0, charges = {},
        cam_x = CAM_X, cam_y = CAM_Y,
        half_w = 640, half_h = 400,
        banner = "", lag = 4,
        stats = {lag = 4, lead = 2, err = 1.5, err_max = 9.0, rewind = 3,
                 snaps = 120, rx = 0, tx = 0},
        zone = "chaos",
        fps = 60, frame_ms = 16.7, rx_rate = 31000, tx_rate = 700,
    })
    ui.finish()
end

-- The floating number, as the interface published it.
--
-- Copied out rather than handed back. `txt` writes into a pool of tables it
-- reuses frame to frame, so a reference kept across two frames is the second
-- frame twice: the first attempt at this compared a value with itself and
-- reported that nothing had moved.
local function floated()
    local st = package.loaded["arena.state"]
    for k = 1, st.n do
        local t = st.text[k]
        if t.s == "+41" then
            return {s = t.s, x = t.x, y = t.y, px = t.px,
                    col = {t.col[1], t.col[2], t.col[3], t.col[4]}}
        end
    end
    return nil
end

-- --- nothing until somebody is killed --------------------------------------

frame(0)
check("no payout on screen before a kill", floated() == nil)

-- --- one arrives where the wreck is ----------------------------------------

-- `M.now` is the clock the last frame ran on, which is where a payout raised
-- between frames takes its birthday from, exactly as arena.script raises one.
ui.payout(CAM_X, CAM_Y, 41)
frame(0.02)
local first = floated()
check("a kill of yours floats its payout", first ~= nil)
check("in the green the feed uses for your own kill",
      first and first.col[1] == pal.PAID[1] and first.col[2] == pal.PAID[2]
          and first.col[3] == pal.PAID[3],
      first and table.concat(first.col, ",") or "nothing drawn")
-- Center of the screen plus the nameplate's own offset, because the wreck is
-- under the camera and that is where the bounty sat.
check("over the wreck rather than over the screen",
      first and math.abs(first.x - (W / 2 + 12)) < 0.5,
      first and tostring(first.x))

-- --- it climbs and goes out ------------------------------------------------

-- Stored bottom-up, so rising is y increasing.
frame(0.7)
local mid = floated()
check("it rises", mid and first and mid.y > first.y,
      first and mid and (first.y .. " -> " .. mid.y))
check("and dims on the way", mid and first and mid.col[4] < first.col[4],
      first and mid and (first.col[4] .. " -> " .. mid.col[4]))

-- Held at full strength to begin with, or it starts vanishing on the frame it
-- appears and nobody finishes reading it.
frame(0.2)
local early = floated()
check("but holds full strength at first",
      early and math.abs(early.col[4] - 0.95) < 1e-6,
      early and tostring(early.col[4]))

-- --- and then it is gone ---------------------------------------------------

frame(1.5)
check("it leaves when its life is up", floated() == nil)
-- Drawn once more from a clock before its birthday, which is what a frame
-- arriving out of order would look like, and must not resurrect it.
frame(0.5)
check("and does not come back", floated() == nil)

-- --- a new arena is not the one it was earned in ---------------------------

-- A frame first, so the payout is born on this clock rather than on the one
-- the last assertion left behind.
frame(2.0)
ui.payout(CAM_X, CAM_Y, 41)
frame(2.02)
check("a fresh payout draws again", floated() ~= nil)
ui.clear_payouts()
frame(2.04)
check("leaving a zone drops it", floated() == nil)

-- --- and a killing spree does not pile up forever --------------------------

for _ = 1, 40 do ui.payout(CAM_X, CAM_Y, 41) end
frame(3.0)
check("many at once all draw", floated() ~= nil)
frame(9.0)
check("and all of them expire", floated() == nil)
ui.payout(CAM_X, CAM_Y, 41)
frame(9.02)
check("with the list still usable afterwards", floated() ~= nil)
ui.clear_payouts()

print(fails == 0 and "PASS" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
