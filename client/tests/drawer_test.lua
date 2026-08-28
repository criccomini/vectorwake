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
for i, n in ipairs({"play", "ship", "friends", "settings"}) do
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

    -- The guest banner: a band on the rail whose whole surface is a way to
    -- the pilot page, beside the one the call sign pill always publishes.
    -- Drawn only when the view says so.
    check("no banner box without the flag", boxes("pilot_page") == 1,
          boxes("pilot_page") .. " boxes")
    ui.begin(harness.layer(), 1440, 810, 1, false, 4.00)
    local banded = view(true)
    banded.banner = true
    ui.menu(banded)
    ui.finish()
    check("the banner publishes its press", boxes("pilot_page") == 2,
          boxes("pilot_page") .. " boxes")
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
    -- The drawer's own width, asked rather than restated: a window with
    -- room draws the column MENU_SCALE larger than a phone does, and a
    -- clamp written as a phone's 390 would pass on one and not the other.
    local wide = select(3, ui.drawer_span())
    check("a finger cannot pull it past the edge it lives on",
          far >= -wide - 0.5, string.format("%.1f of %.1f", far, wide))
    ui.drawer_release(true)
    frame(7.40, false)
    ui.drawer_grab = nil
end

-- --- what the drawer covers stands down --------------------------------------
--
-- The clock band and the dial's corner are the two instruments the menu does
-- not otherwise stand down for, on the argument that a player reading a panel
-- still wants to know the time and where the ship is. On a phone the drawer is
-- the whole window and both were drawn straight through it.
--
-- The question each asks is the overlap, not whether a menu is open, so the
-- answer differs by window: a phone held sideways has the drawer over the
-- clock band and nowhere near the dial.
--
-- The link meter is the other way round now. It is in the panel's own head, so
-- it arrives with the panel whatever the window and leaves with it again. It
-- draws four bars and no caption, so it is asked about by its press box rather
-- than by the words of the frame.

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
                match = {playing = true, left = 169, score = {[0] = 0, [1] = 0}},
                side_names = {[0] = "Pylon", [1] = "Caisson"},
                feed = {}, hurt = 0, charges = {}, cam_x = 3000, cam_y = 3000,
                half_w = w / 2, half_h = h / 2, banner = "", link_bars = 4,
                zone = "melee"})
        if open or ui.drawer_up() then
            local mv = view(open)
            mv.rows = {}
            ui.menu(mv)
        end
        ui.finish()
        local said = {}
        for i = 1, state.n do said[#said + 1] = state.text[i].s end
        -- The words of the frame, and whether the link meter is in it. The
        -- meter draws four rectangles and no caption, so unlike everything
        -- else this file asks about, it cannot be read out of the text. Its
        -- press box is the one thing it publishes under a name.
        local meter = false
        for _, r in ipairs(ui.hits) do
            if r.action == "debug" then meter = true end
        end
        return {words = table.concat(said, "|"), meter = meter}
    end
    local function has(f, word) return f.words:find(word, 1, true) ~= nil end

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
        return before, during, (hud_frame(w, h, 3.50, false))
    end

    -- A phone held upright: the drawer is the window, so the band goes.
    local before, during, after = sweep(390, 844)
    check("upright, the clock band is there before the drawer",
          has(before, "2:49"), before.words)
    check("and gone under it", not has(during, "2:49"), during.words)
    check("and back once it has left", has(after, "2:49"), after.words)

    -- Sideways: the drawer is 390 of 844. It reaches the band, which grows
    -- outward from the middle with the scores and the ratings, and it does not
    -- reach the dial in the far corner.
    before, during, after = sweep(844, 390)
    check("sideways, the drawer covers the clock band",
          has(before, "2:49") and not has(during, "2:49")
              and has(after, "2:49"), during.words)

    -- And the link bars, at every one of those windows: nowhere while the
    -- panel is shut, and in its head while it is open. They are the panel's
    -- now rather than the arena's, so the overlap has nothing to say about
    -- them.
    for _, size in ipairs({{390, 844}, {844, 390}, {1440, 810}}) do
        before, during, after = sweep(size[1], size[2])
        check(string.format("%dx%d has no link meter without the menu",
                            size[1], size[2]),
              not before.meter and not after.meter, "the arena still has one")
        check("and carries it in the panel's head with it", during.meter,
              "the panel came up without it")
    end

    -- A monitor: the drawer is 390 of 1440 and reaches neither instrument.
    during = select(2, sweep(1440, 810))
    check("a monitor keeps the clock band, the drawer being nowhere near it",
          has(during, "2:49"), during.words)
end

-- --- and the screen with no room behind it stands its key down too ---------
--
-- Between one game and the next there is no room to draw, so the waiting
-- screen is what the open menu is standing over. Its key sits in the corner
-- the drawer is docked to, and a panel's ground is a wash rather than a
-- curtain: the key read through the panel that had replaced it, which on a
-- zone change is a MENU flashing up under the menu.

do
    local function wait_frame(now, open)
        ui.begin(harness.layer(), 1440, 810, 1, false, now)
        ui.waiting("")
        if open or ui.drawer_up() then
            local mv = view(open)
            mv.rows = {}
            ui.menu(mv)
        end
        ui.finish()
        local n = 0
        for _, h in ipairs(ui.hits) do
            if h.action == "open" then n = n + 1 end
        end
        return n
    end

    wait_frame(4.0, false)
    check("the waiting screen carries a way into the menu",
          wait_frame(4.1, false) == 1, "no key")
    for _, at in ipairs({4.11, 4.15, 4.20, 4.50}) do wait_frame(at, true) end
    check("and stands it down while the drawer is over it",
          wait_frame(4.60, true) == 0, "the key is still under the panel")
    for _, at in ipairs({4.61, 4.70, 4.90, 5.20}) do wait_frame(at, false) end
    check("and has it back once the drawer has gone",
          wait_frame(5.50, false) == 1, "the key did not come back")
end

-- --- a page does not slide in from the tabs it is already previewing -------
--
-- At the root the stage is a preview of the page the lit tab leads to, so
-- stepping into that page changes which row the cursor is on and nothing else:
-- the rows are the same rows. It slid the width of the drawer for that, which
-- reads as a second drawer arriving over the first and was reported as one. It
-- happened on every step, so walking up out of the tabs and back down into
-- them flapped a full-width panel twice.
--
-- Deeper than that it is a reading arriving over the page that opened it,
-- which is a different surface and still slides.

do
    local state = package.loaded["arena.state"]
    -- Where the page's own type is standing this frame. The row's field is the
    -- drawer's width and does not move; the type inside it rides the slide.
    local function page_at(depth, now)
        state.n = 0
        ui.page_scroll = 0
        ui.begin(harness.layer(), 1440, 810, 1, false, now)
        local v = view(true)
        v.depth = depth
        ui.menu(v)
        ui.finish()
        for i = 1, state.n do
            local t = state.text[i]
            if t and t.s == "Melee" then return t.x end
        end
        return nil
    end

    -- Let the drawer finish arriving, so its own slide is not read as a page's.
    for k = 1, 8 do page_at(1, 20 + k * 0.05) end
    local settled = page_at(1, 21)
    check("the page has somewhere to stand", settled ~= nil, tostring(settled))

    local moved = false
    for _, now in ipairs({21.01, 21.04, 21.08}) do
        if page_at(2, now) ~= settled then moved = true end
    end
    check("stepping from the tabs into their page does not slide",
          not moved, "it moved")

    page_at(2, 22)
    local slid = false
    for _, now in ipairs({22.01, 22.04}) do
        if page_at(3, now) ~= settled then slid = true end
    end
    check("and a reading opened over a page still does", slid,
          "it arrived without one")
end

-- --- and what arrives from the right stays inside the column ---------------
--
-- The drawer is docked against the leading edge of the window and a reading
-- opened over a page comes in from the other side of it. It used to come in
-- across the fight: the page was drawn a full drawer width out and walked
-- back in over the arena, so on anything wider than a phone the type was read
-- over the game for the sixteenth of a second the slide takes. The column
-- cuts what it draws while a page moves, so a reading comes out from behind
-- its own right edge and a press lands on whatever is showing.

do
    local state = package.loaded["arena.state"]
    local DEEP = {{label = "wormhole", detail = "gantry", index = 1},
                  {label = "rung", detail = "ace", index = 2}}

    -- One frame of a page at a depth: what it said, how much of that stood
    -- outside the column, and how many of its boxes reached past the edge.
    local function page(depth, rows, now)
        state.n = 0
        ui.page_scroll = 0
        ui.begin(harness.layer(), 1440, 810, 1, false, now)
        local v = view(true)
        v.depth, v.rows = depth, rows
        ui.menu(v)
        ui.finish()
        local dx, _, dw = ui.drawer_span()
        local said, loose = {}, 0
        for i = 1, state.n do
            local t = state.text[i]
            said[#said + 1] = t.s
            if t.x > dx + dw + 0.01 or t.x < dx - 0.01 then loose = loose + 1 end
        end
        -- Controls only. The two backdrops are ranked rather than ordered
        -- and are meant to reach past the column: the way out is the whole
        -- screen, which is the point of it.
        local reaching = 0
        for _, h in ipairs(ui.hits) do
            if not h.pri and h.x + h.w > dx + dw + 0.01 then
                reaching = reaching + 1
            end
        end
        return table.concat(said, "|"), loose, reaching
    end
    local function has(s, word) return s:find(word, 1, true) ~= nil end

    for k = 1, 8 do page(2, view(true).rows, 30 + k * 0.05) end
    local _, loose, reaching = page(2, view(true).rows, 31)
    check("a settled page is inside the column",
          loose == 0 and reaching == 0,
          loose .. " words and " .. reaching .. " boxes outside")

    -- The step in. The page starts a full drawer width out, so the first
    -- frame of it is entirely behind the edge and says nothing at all.
    local first = page(3, DEEP, 31.005)
    check("the first frame of a reading is still behind the edge",
          not has(first, "Wormhole"), first)

    local arrived = false
    for _, now in ipairs({31.005, 31.02, 31.05, 31.09}) do
        local words, out, hits = page(3, DEEP, now)
        check("nothing of it is drawn over the fight at " .. now,
              out == 0, out .. " words outside: " .. words)
        check("and nothing is pressable out there either at " .. now,
              hits == 0, hits .. " boxes outside")
        if has(words, "Wormhole") then arrived = true end
    end
    check("and it does arrive while the slide runs", arrived,
          "the page never showed")

    local done = page(3, DEEP, 31.30)
    check("and stands whole once it has settled",
          has(done, "Wormhole") and has(done, "Gantry"), done)
    check("and the page it left is gone", not has(done, "Melee"), done)

    -- A word is cut at the nearest letter rather than dropped whole. The mesh
    -- can be cut anywhere and a glyph cannot, so what a run crossing the edge
    -- leaves behind is the letters that fit: somewhere in the slide a word
    -- stands that is the front of one the settled page says in full.
    local whole = {}
    for word in done:gmatch("[^|]+") do whole[word] = true end
    -- Back to the page it came from and in again, since a slide starts on the
    -- frame the depth changes and this one is long over.
    page(2, view(true).rows, 31.40)
    page(2, view(true).rows, 31.60)
    page(3, DEEP, 31.61)
    local cut = false
    for _, now in ipairs({31.611, 31.613, 31.615, 31.617, 31.62, 31.63}) do
        for word in (page(3, DEEP, now)):gmatch("[^|]+") do
            if not whole[word] then
                for full in pairs(whole) do
                    if #word < #full and full:sub(1, #word) == word then
                        cut = true
                    end
                end
            end
        end
    end
    check("and a word crossing the edge is cut at a letter, not dropped",
          cut, "every word arrived whole")
end

print(fails == 0 and "all drawer checks passed"
      or (fails .. " drawer checks failed"))
os.exit(fails == 0 and 0 or 1)
