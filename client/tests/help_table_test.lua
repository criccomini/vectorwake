-- The controls table: what it lists, and that it fits where it is drawn.
--
--     lua5.1 client/tests/help_table_test.lua
--
-- A table of keys is the one piece of interface whose whole job is to be
-- accurate, and the two ways it goes wrong are both invisible from the source.
-- A row can name a key the game does not answer to, which is a lie a reader
-- has no way to catch. And the block can run off the edge of the window it is
-- drawn in, which only happens on the window nobody develops on.
--
-- So this measures the drawn text out of the real M.hud rather than trusting
-- it to a second copy, and reads the rows out of arena/binds.lua, which is
-- where the keys actually are once a pilot has moved one. That the keys in
-- that list are keys the engine reports at all is binds_test's job.

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

local layer = {n = 0, rects = {}}
local function noop(self) self.n = self.n + 1 end
for _, name in ipairs({"arc", "disc", "flush", "frame", "halo", "outline",
                       "quad", "reset", "ring", "seg", "seg_fade",
                       "seg_flat",
                       "skirt", "tri", "tri_fade"}) do
    layer[name] = noop
end
function layer:rect(x, y, w, h, col)
    self.n = self.n + 1
    self.rects[#self.rects + 1] = {x = x, y = y, w = w, h = h}
end

_G.sim = {
    ship_count = function() return 2 end,
    ship_x = function(i) return 100 + i * 180 end,
    ship_y = function(i) return 100 + i * 120 end,
    ship_heading = function() return 0 end,
    ship_alive = function() return 1 end,
    -- The roster is filled while a menu is open now, for the column the menu
    -- draws beside its page, so a stub that draws one has to answer this.
    ship_active = function() return 1 end,
    ship_team = function(i) return i end,
    ship_class = function() return 0 end,
    ship_energy = function() return 100 end,
    ship_max_energy = function() return 100 end,
    ship_kills = function() return 1 end,
    ship_deaths = function() return 1 end,
    ship_assists = function() return 0 end,
    ship_points = function() return 10 end,
    ship_bounty = function() return 34 end,
    ship_up = function() return 0 end,
    ship_level = function() return 1 end,
    ship_charge = function() return 2 end,
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
    in_safe = function() return false end,
    TRIG_GUN = 0, BTN_FIRE = 1,
}

local state = {text = {}, n = 0, version = 0}
package.loaded["arena.state"] = state
package.loaded["arena.touch"] = {
    layout = function() return {charge = {}} end,
    used = false,
}
package.loaded["arena.world"] = {
    build_overview = function() end, forget_overview = function() end,
    overview = {grid = 0, n = 0, rect = {}},
    radar_tiles = {160, 160}, radar_safe = {}, radar_doors = {},
}

local ui = require("arena.ui")

-- --- the harness -----------------------------------------------------------

local ADVANCE = 1233 / 2048

-- Glyphs rather than bytes, the same count ui.lua measures with: the arrow
-- keys are three bytes each and a byte count would put the block wider than
-- it is drawn, which would hide the very overflow this is looking for.
local function glyphs(s)
    local _, cont = string.gsub(s, "[\128-\191]", "")
    return #s - cont
end

local function frame(w, h, dens, open, now, touching, menu_open)
    ui.help = open
    ui.map = false
    layer.rects = {}
    ui.begin(layer, w, h, dens, touching or false, now or 0)
    ui.hud({
        me = 0, menu_open = menu_open or false,
        class_names = {"Apex"},
        pilots = {[0] = {name = "you"}, [1] = {name = "someone"}},
        teams = {}, feed = {}, hurt = 0,
        charges = {{name = "repel", short = "RPL", max = 3, count = 2}},
        cam_x = sim.ship_x(0), cam_y = sim.ship_y(0),
        half_w = w / 2, half_h = h / 2,
        banner = "", lag = 4,
        stats = {lag = 4, lead = 2, err = 1, err_max = 9, rewind = 3,
                 snaps = 120, rx = 0, tx = 0},
        zone = "chaos", fps = 60, frame_ms = 16, rx_rate = 0, tx_rate = 0,
    })
    ui.finish()
    local out = {}
    for i = 1, state.n do
        local t = state.text[i]
        local tw = glyphs(t.s) * t.px * ADVANCE
        local left = t.x
        if t.pivot == "right" then left = t.x - tw
        elseif t.pivot == "center" then left = t.x - tw / 2 end
        out[#out + 1] = {s = t.s, y = h - t.y, left = left,
                         right = left + tw, col = t.col}
    end
    return out
end

-- The list as the table draws it: every control, with the key it is on.
local binds = require("arena.binds")
local ROWS = binds.rows()

local function says(f, s)
    for _, t in ipairs(f) do
        if string.upper(t.s) == string.upper(s) then return t end
    end
    return nil
end

-- --- the first-zone offer is quiet, dismissible, and keyboard-only --------

local function hit_box(action)
    for i, r in ipairs(ui.hits) do
        if r.action == action then return r, i end
    end
    return nil
end

ui.help_prompt = true
local prompt_dim = frame(1280, 800, 1, false, 0)
local dim_label = says(prompt_dim, "PRESS H FOR HELP")
local close_box, close_i = hit_box("help_prompt_close")
local open_box, open_i = hit_box("help_prompt_open")
check("the first-zone offer names the help key", dim_label ~= nil)
check("the offer sits at the bottom of the screen",
      dim_label and dim_label.y > 740, dim_label and dim_label.y)
check("the offer has a close target", close_box ~= nil)
check("the offer itself opens help", open_box ~= nil)
check("the close target wins inside the button",
      close_i and open_i and close_i < open_i)

local prompt_bright = frame(1280, 800, 1, false, 1.5)
local bright_label = says(prompt_bright, "PRESS H FOR HELP")
local function luminance(t)
    if not t or not t.col then return 0 end
    return t.col[1] + t.col[2] + t.col[3]
end
check("the help label slowly brightens",
      luminance(bright_label) > luminance(dim_label) + 0.5)

frame(1280, 800, 1, false, 0, true)
check("a touchscreen is not offered a keyboard key",
      hit_box("help_prompt_open") == nil)
local menu_frame = frame(1280, 800, 1, false, 0, false, true)
check("the offer stays out from under the menu",
      says(menu_frame, "PRESS H FOR HELP") == nil)
local help_frame = frame(1280, 800, 1, true, 0)
check("opening the controls replaces the offer",
      says(help_frame, "PRESS H FOR HELP") == nil)
ui.help_prompt = false

-- The same word, on the row that carries it.
--
-- Two of the names in the table are also words the interface says elsewhere:
-- MENU and PLAYERS are the key caps in the top corner. Matching on the word
-- alone found those instead and put the name column four hundred points wide.
-- A row's sentence is unique, so its baseline is what identifies the row, and
-- the key and the name are whatever share it.
local function at_row(f, s, y)
    for _, t in ipairs(f) do
        if string.upper(t.s) == string.upper(s) and math.abs(t.y - y) < 6 then
            return t
        end
    end
    return nil
end

-- --- shut, it draws nothing ------------------------------------------------

do
    local f = frame(1280, 800, 1, false)
    local leaked = nil
    for _, r in ipairs(ROWS) do
        if says(f, r.what) then leaked = r.what end
    end
    check("nothing of it is drawn while it is shut", leaked == nil, leaked)
end

-- --- open, every row is there ----------------------------------------------

do
    local f = frame(1280, 800, 1, true)
    check("it names itself", says(f, "CONTROLS") ~= nil)
    local missing = {}
    for _, r in ipairs(ROWS) do
        local d = says(f, r.what)
        if not (d and at_row(f, r.show, d.y) and at_row(f, r.name, d.y)) then
            missing[#missing + 1] = r.name
        end
    end
    check("every row draws all three of its columns", #missing == 0,
          table.concat(missing, ", "))
end

-- --- the columns are columns ----------------------------------------------
--
-- Three left edges, each shared by every row. A sentence that started under
-- the name column would read as a fourth thing rather than as the third.

do
    local f = frame(1280, 800, 1, true)
    local kx, nx, dx = {}, {}, {}
    for _, r in ipairs(ROWS) do
        local d = says(f, r.what)
        kx[#kx + 1] = at_row(f, r.show, d.y).left
        nx[#nx + 1] = at_row(f, r.name, d.y).left
        dx[#dx + 1] = d.left
    end
    local function spread(t)
        local lo, hi = t[1], t[1]
        for _, v in ipairs(t) do lo = math.min(lo, v) hi = math.max(hi, v) end
        return hi - lo
    end
    check("the keys share a left edge", spread(kx) < 1, spread(kx))
    check("the names share a left edge", spread(nx) < 1, spread(nx))
    check("the sentences share a left edge", spread(dx) < 1, spread(dx))
    check("and the three run left to right",
          kx[1] < nx[1] and nx[1] < dx[1])
end

-- --- it fits the window it is in -------------------------------------------
--
-- Including the narrow ones. A phone held sideways is 844 points by 390 at
-- two pixels per point, and the longest sentence in the table is wider than
-- that at full size, so the block has to come down to meet it.

for _, win in ipairs({{1280, 800, 1}, {844 * 2, 390 * 2, 2}, {640, 480, 1}}) do
    local w, h, dens = win[1], win[2], win[3]
    local f = frame(w, h, dens, true)
    local off = nil
    for _, t in ipairs(f) do
        if t.left < -1 or t.right > w + 1 or t.y < 0 or t.y > h then
            off = string.format("%q spans %.0f..%.0f at y %.0f",
                                t.s, t.left, t.right, t.y)
        end
    end
    check(string.format("everything fits in %dx%d at %dx", w, h, dens),
          off == nil, off)
end

-- --- and a phone is told about the controls it cannot read ----------------
--
-- These rows were written out a second time in the menu once, and drifted:
-- the map moved onto the dial and the page a phone reads went on describing a
-- game without it. One list fixes that, and this pins the part of it a sweep
-- cannot judge.
--
-- Not every tappable thing needs a sentence. Most of what a finger lands on
-- in the arena is a word on a card: INVITE, WATCH, a room number. Those say
-- what they do by being read. What needs saying is the controls that carry no
-- word at all, or that live behind a card you have to know to open, and that
-- is a judgement rather than something a regex can settle. So the judgement
-- is written down here and checked, instead of being left in somebody's head.

do
    -- Wearing no label a player can read, so a phone learns them here or not
    -- at all. The dial is a picture and the pads are marks.
    local MUST_SAY = {"turn left", "thrust", "reverse", "guns", "bombs", "repel",
                      "burst", "mine", "multifire", "map", "players"}
    local pad = {}
    for _, r in ipairs(ROWS) do pad[r.name] = r.pad end

    local silent = {}
    for _, name in ipairs(MUST_SAY) do
        if not pad[name] or pad[name] == "" then silent[#silent + 1] = name end
    end
    check("every unlabeled control has a sentence for a thumb", #silent == 0,
          table.concat(silent, ", "))

    -- The ones that say nothing, and why. The controls page is the page being
    -- read; turn right shares the stick with turn left and is named by it.
    -- Page Up and Page Down are replaced by tapping the pilot row. Anything
    -- else arriving with no `pad` is a control a phone has quietly lost.
    local QUIET = {controls = true, ["turn right"] = true,
                   ["previous player"] = true, ["next player"] = true}
    local mute = {}
    for _, r in ipairs(ROWS) do
        if not r.pad and not QUIET[r.name] then mute[#mute + 1] = r.name end
    end
    check("and only the deliberate ones are keyboard-only", #mute == 0,
          table.concat(mute, ", "))

    -- A thumb sentence that names a key is a sentence written for the wrong
    -- device, which is the shape the drift took last time.
    local keyed = {}
    for _, r in ipairs(ROWS) do
        if r.pad and (r.pad:find("[Pp]ress ") or r.pad:find("[Kk]ey")) then
            keyed[#keyed + 1] = r.name
        end
    end
    check("and no thumb sentence names a key", #keyed == 0,
          table.concat(keyed, ", "))

    -- What a phone is handed is every row a thumb can work, which is the whole
    -- list less the deliberate keyboard-only set above. Derived from that set
    -- so adding another honest desktop control cannot stale a second count.
    local thumbed, keyboard_only = 0, 0
    for _, r in ipairs(ROWS) do
        if r.pad then thumbed = thumbed + 1
        elseif QUIET[r.name] then keyboard_only = keyboard_only + 1 end
    end
    check("a phone is offered every control it can work",
          thumbed == #ROWS - keyboard_only,
          thumbed .. " of " .. #ROWS)

    -- And the menu builds its page from this list rather than from a second
    -- copy, which is the whole point of the list being shared. Read out of
    -- the source, because the alternative is exporting the menu's page table
    -- to prove it.
    local mf = io.open("client/arena/menu.lua")
    local mbody = mf and mf:read("*a") or ""
    if mf then mf:close() end
    check("and the menu's controls page is generated from it",
          mbody:find('require("arena.binds")', 1, true) ~= nil
          and mbody:match("for i, c in ipairs%(binds%.rows%(%)%) do"),
          "menu.lua writes its own rows again")
end

if fails > 0 then
    print(fails .. " failed")
    os.exit(1)
end
print("all good")
