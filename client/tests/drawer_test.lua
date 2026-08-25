-- The menu comes in from the edge and leaves the same way.
--
--     lua5.1 client/tests/drawer_test.lua
--
-- The column is docked to the left edge and covers the corner keys it is
-- docked over, so a press on the menu key used to swap one screen for another
-- with nothing on screen saying where the new one came from. It slides now,
-- and a thumb can push it back off.
--
-- None of this is visible to the rest of the suite, which draws every frame on
-- a clock that never moves and therefore always sees the drawer settled. What
-- is here is the arithmetic of the slide itself, run on a clock that does move.

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

local harness = require("tests.ui_harness")
-- A room with somebody in it, because the checks at the foot of this file draw
-- the arena's own instruments and the stub harness reports an empty world.
local ui = harness.install({sim = setmetatable({
    ship_count = function() return 4 end,
    ship_active = function() return 1 end,
    ship_alive = function() return 1 end,
}, {__index = function() return function() return 0 end end})})

local RAIL = {}
for i, n in ipairs({"play", "ship", "upgrades", "friends", "standings",
                    "settings"}) do
    RAIL[i] = {label = n, icon = n == "play" and "zones" or n, index = i}
end

local function view(open)
    return {depth = 1, sel = 1, rail = RAIL, rail_sel = 1, focus = "rail",
            home = false, scenery = true, closable = true, at = "play",
            open = open, pilot = {name = "Krait 4", rivets = 0},
            rows = {{label = "melee", detail = "3 + 5 AI", index = 1,
                     pick = true, players = 3, bots = 5, live = true}}}
end

-- One frame at a given moment. Returns the drawer's left edge, which is what
-- the slide actually moves, and how far in it says it is.
local function frame(now, open)
    ui.begin(harness.layer(), 1440, 810, 1, false, now)
    ui.menu(view(open))
    ui.finish()
    return (select(1, ui.drawer_span())), ui.drawer
end

local function boxes(kind)
    local n = 0
    for _, h in ipairs(ui.hits) do
        if h.action == kind then n = n + 1 end
    end
    return n
end

-- --- a still clock draws it settled ----------------------------------------
--
-- The rest of the suite depends on this: it never advances the clock, so every
-- layout check would be measuring a panel halfway off the screen otherwise.

local x = frame(0, true)
check("a clock that never moves draws the drawer flush",
      math.abs(x) < 0.5, string.format("%.1f", x))

-- --- coming in --------------------------------------------------------------

do
    -- From shut. The check above left it settled open, and a drawer already
    -- in has nothing to slide: what animates is a change of mind, not a frame.
    frame(0.90, false)
    frame(0.99, false)
    local x0 = frame(1.00, true)
    check("the first frame of an open starts off the edge",
          x0 < -300, string.format("%.1f", x0))
    local last = x0
    local monotone = true
    for _, at in ipairs({1.04, 1.08, 1.12}) do
        local xn = frame(at, true)
        if xn <= last then monotone = false end
        last = xn
    end
    check("and each frame brings it further in", monotone,
          string.format("stalled at %.1f", last))
    local settled = frame(1.30, true)
    check("and it settles flush against the edge",
          math.abs(settled) < 0.5, string.format("%.1f", settled))
    -- Fast out and slow in, which is what stops a 160ms slide reading as a
    -- jump: a quarter of the way through the clock it is already most of the
    -- way in.
    frame(1.40, false)
    frame(1.60, false)
    frame(2.00, true)
    local quarter = select(2, frame(2.04, true))
    check("the slide eases rather than running at one speed",
          quarter > 0.5, string.format("%.2f of the way at a quarter of the "
                                       .. "clock", quarter))
end

-- --- going out --------------------------------------------------------------

do
    frame(3.00, true)
    local a = frame(3.00, false)
    local b = frame(3.06, false)
    check("a dismissed drawer heads back off the edge", b < a,
          string.format("%.1f then %.1f", a, b))
    check("and is still on screen while it goes", ui.drawer_up(),
          "gone before it had left")
    frame(3.30, false)
    check("and is finished once the slide is over", not ui.drawer_up(),
          string.format("still %.3f in", ui.drawer))
end

-- --- a drawer on its way out answers nothing --------------------------------
--
-- It is drawn, because that is the point of drawing it, but the menu is shut
-- and the game under it is live. A press during the slide belongs to the arena.

do
    frame(4.00, true)
    check("an open drawer publishes its stops", boxes("rail") == #RAIL,
          boxes("rail") .. " of " .. #RAIL)
    check("and a way out", boxes("close") > 0, "no close")
    frame(4.04, false)
    check("a closing drawer publishes no stops", boxes("rail") == 0,
          boxes("rail") .. " left")
    check("and no way out", boxes("close") == 0, boxes("close") .. " left")
end

-- --- a thumb pushes it off --------------------------------------------------

do
    frame(5.00, true)
    ui.drawer_grab = -200
    local held = frame(5.02, true)
    check("the drawer follows the finger dragging it",
          math.abs(held + 200) < 1.5, string.format("%.1f", held))
    -- The clock is still running underneath; the finger wins while it is down.
    local still = frame(5.10, true)
    check("and stays where the finger has it while the clock runs on",
          math.abs(still + 200) < 1.5, string.format("%.1f", still))

    -- Let go short of the threshold: it goes back rather than sitting ajar.
    ui.drawer_release(false)
    check("letting go short of the mark sends it back",
          ui.drawer_grab == nil, "still held")
    local back = frame(5.30, true)
    check("and it returns flush", math.abs(back) < 0.5,
          string.format("%.1f", back))

    -- Let go past it: the slide carries on from where the finger left it
    -- rather than starting over from flush.
    frame(6.00, true)
    ui.drawer_grab = -300
    frame(6.02, true)
    ui.drawer_release(true)
    check("letting go past the mark carries on from the finger",
          ui.drawer > 0 and ui.drawer < 0.4,
          string.format("%.2f", ui.drawer))
    local gone = frame(6.30, false)
    check("and it finishes off the edge", gone < -300,
          string.format("%.1f", gone))
end

-- --- it never comes out the wrong side --------------------------------------

do
    frame(7.00, true)
    ui.drawer_grab = -10000
    local far = frame(7.02, true)
    check("a finger cannot pull it past the edge it lives on",
          far >= -390 - 0.5, string.format("%.1f", far))
    ui.drawer_release(true)
    frame(7.40, false)
    ui.drawer_grab = nil
end

-- --- what the drawer covers stands down --------------------------------------
--
-- The clock band and the dial's corner are the two instruments the menu does
-- not otherwise stand down for, on the argument that a player reading a panel
-- still wants to know the time and the state of the line. On a phone the
-- drawer is the whole window and both were drawn straight through it.
--
-- The question each asks is the overlap, not whether a menu is open, so the
-- answer differs by window: a phone held sideways has the drawer over the
-- clock band and nowhere near the dial.

do
    local SEATS = {}
    for i = 0, 3 do
        SEATS[i] = {name = "p" .. i, label = i == 0 and "human" or "bot",
                    ai = i > 0}
    end
    local state = package.loaded["arena.state"]

    local function hud_frame(w, h, now, open)
        state.n = 0
        ui.begin(harness.layer(), w, h, 1, false, now)
        ui.hud({me = 0, watch = {subject = 0}, side = 0, viewer_name = "p0",
                menu_open = open, pilots = SEATS, watchers = {}, teams = {},
                match = {playing = true, left = 169, score = {[0] = 0, [1] = 0},
                         ladder = {rung = 3, streak = 1}},
                side_names = {[0] = "Pylon", [1] = "Caisson"},
                feed = {}, hurt = 0, charges = {}, cam_x = 3000, cam_y = 3000,
                half_w = w / 2, half_h = h / 2, banner = "", link_bars = 4,
                zone = "ladder"})
        if open or ui.drawer_up() then
            local mv = view(open)
            mv.rows = {}
            ui.menu(mv)
        end
        ui.finish()
        local said = {}
        for i = 1, state.n do said[#said + 1] = state.text[i].s end
        return table.concat(said, "|")
    end
    local function has(s, word) return s:find(word, 1, true) ~= nil end

    -- Shut, open and settled, then shut and settled again.
    local function sweep(w, h)
        hud_frame(w, h, 1.0, false)
        hud_frame(w, h, 1.1, false)
        local before = hud_frame(w, h, 2.0, false)
        for _, at in ipairs({2.01, 2.05, 2.10, 2.40}) do
            hud_frame(w, h, at, true)
        end
        local during = hud_frame(w, h, 2.60, true)
        for _, at in ipairs({2.61, 2.70, 2.90, 3.20}) do
            hud_frame(w, h, at, false)
        end
        return before, during, hud_frame(w, h, 3.50, false)
    end

    -- A phone held upright: the drawer is the window, so both go.
    local before, during, after = sweep(390, 844)
    check("upright, the clock band is there before the drawer",
          has(before, "2:49"), before)
    check("and gone under it", not has(during, "2:49"), during)
    check("and back once it has left", has(after, "2:49"), after)
    check("upright, the dial's corner goes with it",
          has(before, "LINK") and not has(during, "LINK")
              and has(after, "LINK"), during)

    -- Sideways: the drawer is 390 of 844. It reaches the band, which grows
    -- outward from the middle with the scores and the ratings, and it does not
    -- reach the dial in the far corner.
    before, during, after = sweep(844, 390)
    check("sideways, the drawer covers the clock band",
          has(before, "2:49") and not has(during, "2:49")
              and has(after, "2:49"), during)
    check("and leaves the dial's corner alone",
          has(during, "LINK"), "the dial went with it")

    -- A monitor: the drawer is 390 of 1440 and reaches neither.
    during = select(2, sweep(1440, 810))
    check("a monitor keeps both, the drawer being nowhere near them",
          has(during, "2:49") and has(during, "LINK"), during)
end

print(fails == 0 and "all drawer checks passed"
      or (fails .. " drawer checks failed"))
os.exit(fails == 0 and 0 or 1)
