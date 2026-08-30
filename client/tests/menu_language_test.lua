-- One design language, held to across every menu in the game.
--
--     lua5.1 client/tests/menu_language_test.lua
--
-- The other interface tests each ask about one surface. This asks the question
-- none of them can: whether two surfaces still agree.
--
-- They did not. The games and account lists set their names in the HUD's
-- twelve point mono capitals, because a list grew out of a strip drawn over a
-- fight; the settings page set its in the menu's own face at seventeen,
-- sentence case; a hull's slots were a third shape again, their own height and
-- their own arrows. Walking from the games list into settings into a ship
-- changed dialect twice. Every one of the three was defensible where it was
-- written and none of them had been decided.
--
-- So the rules below are cross-surface by construction: each drives two or
-- more of the real panels and asks whether what came back is the same. A test
-- that drove one of them would pass forever while the language came apart.
--
-- What it does not cover is anything one surface owns alone; landing_test,
-- column_test, row_field_test and card_test keep those.

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
local layer = harness.layer()

-- Every rectangle laid down this frame, so a wash can be told from a fill.
local rects = {}
local W, H = 1440, 810
layer.rect = function(_, x, y, w, h, col)
    rects[#rects + 1] = {x = x, y = H - y - h, w = w, h = h, col = col}
end

package.loaded["arena.net"] = {
    teams = {}, my_team = 0, transport = function() return {} end,
    my_team_name = function() return "" end, protocol = 5,
}
package.loaded["arena.account"] = {name = "", claimed = false,
                                   load = function() end, base = ""}
package.loaded["arena.directory"] = {rows = {}, note = "",
                                     tick = function() end,
                                     aim = function() end, pilot_name = ""}
package.loaded["arena.sfx"] = {ui = function() end,
                               master_gain = function() end,
                               music_gain = function() end}
package.loaded["arena.world"] = {
    build_overview = function() end, forget_overview = function() end,
    overview = function() return {grid = 0, rects = {}} end,
    radar_tiles = {2960, 2960}, radar_safe = {}, radar_doors = {},
}
package.loaded["arena.touch"] = {layout = function() return {charge = {}} end,
                                 used = false}

-- A room with hulls in it, because the landing is a live one watched from the
-- stands and `M.hud` draws nothing at all for an empty world.
local ui = harness.install({
    state = {text = {}, n = 0, version = 0},
    sim = setmetatable({
        ship_count = function() return 8 end,
        ship_active = function() return 1 end,
        ship_alive = function() return 1 end,
        ship_x = function(i) return 3000 + i * 90 end,
        ship_y = function(i) return 3000 + i * 60 end,
        ship_team = function(i) return i < 4 and 0 or 1 end,
        ship_energy = function() return 100 end,
        ship_max_energy = function() return 100 end,
        has_trigger = function() return true end,
        weapon_count = function() return 0 end,
        flag_count = function() return 0 end,
        flag_at = function() return 0, 0, 255 end,
        map_coarse = function() return nil end,
        BTN_FIRE = 1,
    }, {__index = function() return function() return 0 end end}),
})
local state = package.loaded["arena.state"]
local pal = require("arena.palette")

-- --- the four surfaces, as the arena hands them over -----------------------

local LAND = {
    name = "Vesper 412", zone = "Team Battle", ship = "Wedge",
    zones = {
        {label = "Team Battle", zone = "melee", live = true,
         format = "4v4", here = true},
        {label = "Duel", zone = "duel", live = true, format = "1v1"},
    },
    account = {
        {label = "sign up", act = "claim", offer = true,
         note = "keep your points"},
        {label = "new name", act = "reroll"},
        {rule = true},
        {label = "log in", act = "enter_login"},
    },
    panel = {
        at = 1, pages = 8, class = 1, label = "Wedge", mine = true,
        bars = {0.2, 0.14, 0.09, 0.71, 0.0}, free = 2, credits = 7,
        rows = {
            {kind = "sect", label = "gun"},
            {kind = "slot", slot = 7, label = "Spray", value = 2, cap = 5,
             can_up = true, can_down = true},
            {kind = "slot", slot = 8, label = "Bounce", value = 0, cap = 1,
             toggle = true, can_up = true, can_down = false},
        },
    },
}

local SEATS = {[0] = {name = "you", ship = 1, team = 0, alive = true,
                      kills = 0, deaths = 0}}

-- One frame of the landing with `open` standing on it, or of the in-match
-- column when `menu` is given instead.
local function frame(o)
    o = o or {}
    rects = {}
    state.n = 0
    ui.details = false
    ui.col_open = o.open or nil
    ui.col_sel, ui.col_sel_value = o.sel, o.sel_value
    ui.page_scroll = 0
    ui.panel_shut()
    ui.begin(layer, W, H, 1, false, 0)
    ui.hud({
        me = 0, watch = {subject = 0},
        landing = not o.menu or nil, land = not o.menu and LAND or nil,
        side = 0, viewer_name = "you", menu_open = o.menu and true or false,
        pilots = SEATS, watchers = {}, teams = {},
        match = {playing = true, left = 107, score = {[0] = 3, [1] = 5}},
        side_names = {[0] = "Pylon", [1] = "Caisson"},
        feed = {}, hurt = 0, charges = {}, cam_x = 3000, cam_y = 3000,
        half_w = W / 2, half_h = H / 2, banner = "", link_bars = 4,
        zone = "melee", room = 1,
    })
    if o.menu then ui.menu(o.menu) end
    ui.finish()
end

local function settings_view()
    return {open = true, at = "settings", page = "settings",
            stops = {{stop = "leave", label = "leave",
                      value = "to the stands"},
                     {stop = "settings", label = "settings",
                      mark = "settings", open = true}},
            rows = {{sect = "audio"},
                    {label = "Sound", choice = 2, choices = 3,
                     detail = "half", pick = true},
                    {label = "Music", choice = 1, choices = 3,
                     detail = "quiet", pick = true}}}
end

-- Where a line of type landed, and at what size and in what face.
local function said(s)
    for i = 1, state.n do
        local t = state.text[i]
        if t and t.s == s then return t end
    end
    return nil
end

local function hit_of(action)
    for _, r in ipairs(ui.hits) do
        if r.action == action then return r end
    end
    return nil
end

-- --- one voice --------------------------------------------------------------
--
-- The menu speaks in its own face, in sentence case. Every panel, on both
-- columns. This is the rule that was broken twice over and the one most likely
-- to break again, because the case a string is drawn in comes off the screen it
-- is drawn on rather than off the thing it says.

do
    frame({open = "zone"})
    local team = said("Team Battle")
    check("a games row is set in the menu's own face",
          team and team.font == "menu",
          team and tostring(team.font) or "the row was not drawn")
    check("and at the row rung of the ladder",
          team and math.abs(team.px - ui.TYPE.ROW) < 0.001,
          team and tostring(team.px) or "missing")
    check("and not in the HUD's capitals", said("TEAM BATTLE") == nil)

    frame({open = "account"})
    check("an account act speaks the same way",
          said("Sign up") ~= nil and said("SIGN UP") == nil,
          "the acts are not in the menu's voice")
    local acct = said("Sign up")
    check("in the same face and at the same rung",
          acct and acct.font == "menu"
          and math.abs(acct.px - ui.TYPE.ROW) < 0.001)

    frame({open = "ship"})
    check("and so does a hull's slot",
          said("Spray") ~= nil and said("SPRAY") == nil)
    local slot = said("Spray")
    check("in the same face and at the same rung",
          slot and slot.font == "menu"
          and math.abs(slot.px - ui.TYPE.ROW) < 0.001,
          slot and (tostring(slot.font) .. " " .. tostring(slot.px)) or "gone")

    frame({menu = settings_view()})
    local sound = said("Sound")
    check("and a settings row, which always did",
          sound and sound.font == "menu"
          and math.abs(sound.px - ui.TYPE.ROW) < 0.001)
end

-- --- one row ----------------------------------------------------------------
--
-- Four panels, one shape. A name starts the same distance inside the glass on
-- every one of them, which is the measure that used to differ: twelve points
-- on a list, twelve on a hull's slots against a panel of a different width,
-- and the settings page's own pad on top of its inset.

do
    local function name_inset(open, word, menu)
        frame({open = open, menu = menu})
        local t = said(word)
        if not t then return nil end
        -- The panel is what the row is inset from, and every panel on a given
        -- window stands in the same place, so its left edge is the one the
        -- back on its head is published at.
        local head = hit_of(menu and "menu_back" or "land_back")
        if not head then return nil end
        return t.x - head.x
    end
    local zone = name_inset("zone", "Team Battle")
    local acct = name_inset("account", "Sign up")
    local ship = name_inset("ship", "Spray")
    local sets = name_inset(nil, "Sound", settings_view())
    check("every panel insets its names by the same measure",
          zone and acct and ship and sets
          and math.abs(zone - acct) < 1 and math.abs(zone - ship) < 1
          and math.abs(zone - sets) < 1,
          string.format("zone %s, account %s, ship %s, settings %s",
                        tostring(zone), tostring(acct), tostring(ship),
                        tostring(sets)))

    -- And stands them the same height apart. A games row was thirty points on
    -- a monitor against a settings row's forty four, which is the same object
    -- drawn at two sizes: walking from one panel into the other changed how
    -- far a thumb had to travel between two choices.
    local function pitch(open, a, b, menu)
        frame({open = open, menu = menu})
        local first, second = said(a), said(b)
        if not (first and second) then return nil end
        return math.abs(second.y - first.y)
    end
    local list = pitch("zone", "Team Battle", "Duel")
    local slots = pitch("ship", "Spray", "Bounce")
    local page = pitch(nil, "Sound", "Music", settings_view())
    check("and stands its rows the same height apart",
          list and slots and page
          and math.abs(list - slots) < 1 and math.abs(list - page) < 1,
          string.format("list %s, slots %s, settings %s", tostring(list),
                        tostring(slots), tostring(page)))
end

-- --- one wash ---------------------------------------------------------------
--
-- Where a hand is, said at one weight in one shape wherever a row is drawn.
-- The lists lit a flat field at the full weight and the pages washed theirs,
-- which is one idea drawn two ways: the same row moved between two panels
-- changed how being under the cursor looked.
--
-- Both are flat now. The wash put part of the weight in a skirt against the
-- left edge, which is the right mark against a lit rule and was written for
-- the drawer, which had one; a panel is outlined all the way round, so what
-- the skirt drew was a brighter quarter of a row with an edge where it ran
-- out and nothing there to explain it.

do
    local function washed(open, weight, menu)
        frame({open = open, menu = menu,
               sel = open == "zone" and "land_pick_zone" or nil,
               sel_value = open == "zone" and "duel" or nil})
        for _, r in ipairs(rects) do
            local c = r.col
            if c and math.abs(c[1] - pal.FRIEND[1]) < 0.01
               and math.abs(c[2] - pal.FRIEND[2]) < 0.01
               and math.abs((c[4] or 0) - weight) < 0.005 then
                return r
            end
        end
        return nil
    end
    check("a list lights the row under the cursor at the menu's weight",
          washed("zone", ui.LIT.CURSOR) ~= nil,
          "no wash at the cursor's weight")
    check("and the row you are already in at the standing weight",
          washed("zone", ui.LIT.HERE) ~= nil,
          "no wash at the standing weight")

    -- And it runs the glass, edge to edge, on every one of them.
    --
    -- Reported off the zone panel: the highlight stopped short of both sides
    -- and left plain panel showing either side of it. A row lit itself at its
    -- own type column, fourteen points in, and the lists lit the glass as
    -- well, so a list row came out with a brighter band up the middle and a
    -- settings row came out as a box floating on the panel.
    --
    -- Measured against the box a press lands in rather than against a number
    -- written down here, which is the same rectangle by construction now: what
    -- lights up is what a press lands on. The four surfaces each name the row
    -- their cursor is standing on.
    local EDGE = {
        {open = "zone", sel = "land_pick_zone", sel_value = "duel"},
        {open = "account", sel = "land_pick_account", sel_value = 1},
        {open = "ship", sel = "land_kit_row", sel_value = 8},
        {sel = "menu_row", sel_value = 2, menu = settings_view()},
    }
    for _, s in ipairs(EDGE) do
        frame({open = s.open, sel = s.sel, sel_value = s.sel_value,
               menu = s.menu})
        local lit
        for _, r in ipairs(rects) do
            local c = r.col
            if c and math.abs(c[1] - pal.FRIEND[1]) < 0.01
               and math.abs(c[2] - pal.FRIEND[2]) < 0.01
               and math.abs((c[4] or 0) - ui.LIT.CURSOR) < 0.005 then
                lit = r
                break
            end
        end
        local box
        for _, r in ipairs(ui.hits) do
            if r.action == s.sel and r.value == s.sel_value then
                box = r
                break
            end
        end
        local name = s.open or "settings"
        check(name .. " lights its row the full width of the glass",
              lit and box and math.abs(lit.x - box.x) < 1
              and math.abs(lit.w - box.w) < 1,
              lit and box
              and string.format("lit %.0f..%.0f, pressed %.0f..%.0f", lit.x,
                                lit.x + lit.w, box.x, box.x + box.w)
              or (lit and "no press box" or "nothing lit"))
    end
end

-- --- one head ---------------------------------------------------------------
--
-- Every panel heads itself once, and the head carries the way back. The ship
-- panel used to head itself twice: the section's name on one line and the
-- roster's pager on another, which is two answers to "where am I".

do
    for _, open in ipairs({"zone", "account", "ship"}) do
        frame({open = open})
        local backs = 0
        for _, r in ipairs(ui.hits) do
            if r.action == "land_back" then backs = backs + 1 end
        end
        check("the " .. open .. " panel heads itself exactly once",
              backs == 1, backs .. " ways back")
    end
    -- And the roster is walked on a row of that panel rather than on a head of
    -- its own: the arrows are published, and the name between them is the
    -- press that flies the ship.
    frame({open = "ship"})
    local pages = 0
    for _, r in ipairs(ui.hits) do
        if r.action == "land_page_ship" then pages = pages + 1 end
    end
    check("and the roster is walked on one of its rows",
          pages == 2 and hit_of("land_pick_ship") ~= nil,
          pages .. " arrows")
end

print(fails == 0 and "all menu language checks passed"
      or (fails .. " menu language checks failed"))
os.exit(fails == 0 and 0 or 1)
