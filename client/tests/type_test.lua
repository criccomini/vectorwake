-- The menu's type: five sizes, six inks, and a contrast floor under all of it.
--
--     lua5.1 client/tests/type_test.lua
--
-- This measures a rule that held for one release and then quietly stopped,
-- which is the kind that needs a test rather than a paragraph. `interface.md`
-- said dim labels draw at DIM's full alpha, and the comment over `LBL_PX` said
-- it again and worked through the arithmetic. Then thirty-three call sites
-- passed an explicit alpha, and a third of the type in the menu went under the
-- 4.5:1 small type wants: a tab row at 3.33, a games row's own figures at
-- 1.97, and a field's own placeholder at 1.94, which is the box telling you
-- what to type.
--
-- Nothing caught it because nothing was looking. Every one of those sites is
-- defensible on its own line, and the number that condemns it is a function of
-- the color, the alpha and the ground three files apart.
--
-- So this draws the real menu, every page of it, and reads back what each run
-- of type actually asked for. Three checks:
--
--   1. every run clears WCAG AA on the ground it lands on
--   2. every size is on the ladder
--   3. prose is set in the menu face and figures in the mono
--
-- The ground is the column's: 0x03050a at 0.86 over the arena. A run under the
-- pointer sits on a lit field instead, and a run on the row you are already on
-- sits on a quieter one, so all three are measured and the worst is the one
-- that counts.

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
local pal = require("arena.palette")
local layer = harness.layer()

local SIM = setmetatable({
    ship_count = function() return 0 end,
    ship_active = function() return 0 end,
    weapon_count = function() return 0 end,
    flag_count = function() return 0 end,
    map_coarse = function() return nil end,
}, {__index = function() return function() return 0 end end})

local ui = harness.install({sim = SIM})

-- --- what a color is worth ------------------------------------------------
--
-- WCAG 2.1: sRGB relative luminance, and the foreground composited over the
-- ground at whatever alpha it was queued with. Written out rather than pulled
-- in, because the whole point of the file is to owe nothing to the code it is
-- checking.

local function chan(c)
    if c <= 0.03928 then return c / 12.92 end
    return ((c + 0.055) / 1.055) ^ 2.4
end

local function lum(r, g, b)
    return 0.2126 * chan(r) + 0.7152 * chan(g) + 0.0722 * chan(b)
end

local function over(fg, a, bg)
    return {fg[1] * a + bg[1] * (1 - a),
            fg[2] * a + bg[2] * (1 - a),
            fg[3] * a + bg[3] * (1 - a)}
end

local function contrast(a, b)
    local la, lb = lum(a[1], a[2], a[3]), lum(b[1], b[2], b[3])
    if la < lb then la, lb = lb, la end
    return (la + 0.05) / (lb + 0.05)
end

-- The three grounds a run of type in the menu can land on. The column is the
-- wash `M.menu` lays down over the arena; the other two are that wash with a
-- lit field on it, at the two weights `LIT` publishes.
local COLUMN = over(pal.rgb(0x03050a), 0.86, pal.BG)
local GROUNDS = {
    {"the column", COLUMN},
    {"a row under the pointer", over(pal.FRIEND, ui.LIT.CURSOR, COLUMN)},
    {"the row you are on", over(pal.FRIEND, ui.LIT.HERE, COLUMN)},
}

-- 4.5:1 for text, and 3:1 once it is large enough to count as large: 24 points
-- at the browser's own pixel, which is where WCAG puts the line for a face
-- that is not bold.
local function floor_for(px, density)
    return px / density >= 24 and 3.0 or 4.5
end

-- --- the pages ------------------------------------------------------------

local RAIL = {}
for i, e in ipairs({{"ship", "ship"}, {"settings", "settings"}}) do
    RAIL[i] = {label = e[1], icon = e[2], index = i}
end

-- Rows chosen for the states that used to fail rather than for the states that
-- are easy to draw: somebody else's name in their own side's color, a row
-- wearing the mark for where you already are, an empty field wearing its
-- placeholder.
local PAGES = {
    {"teams", {at = "teams", rail_sel = 1, rows = {
        {label = "Pylon", named = true, tint = 1, index = 1, pick = true,
         detail = "3 + 1 AI", mark = true},
        {label = "Caisson", named = true, tint = 2, index = 2, pick = true,
         detail = "4"},
        {label = "new team", detail = "yours", index = 3, pick = true},
    }}},
    {"ship", {at = "ship", rail_sel = 1, rows = {
        {sect = "bomb", label = "Bomb bounce", index = 1, detail = "120",
         note = "a round that comes back"},
        {label = "Bomb prox", index = 2, detail = "300"},
        {label = "Bomb freeze", index = 3, detail = "900", mark = true},
    }}},
    {"settings", {at = "settings", rail_sel = 2, rows = {
        {sect = "flight", label = "Invert thrust", index = 1, choice = 1,
         choices = 2, note = "which way the stick points"},
        {label = "Deadzone", index = 2, choice = 3, choices = 5},
    }}},
}

-- One frame of one page, and everything it wrote down.
local function runs(page, over_, w, h, density)
    local st = package.loaded["arena.state"]
    st.n = 0
    ui.begin(layer, w, h, density, false, 0)
    local v = {depth = 1, sel = 1, rail = RAIL, focus = "stage",
               scenery = true, closable = true,
               pilot = {name = "Krait 4", rivets = 310}}
    for k, val in pairs(over_) do v[k] = val end
    ui.menu(v)
    ui.finish()
    local out = {}
    for i = 1, st.n do
        local t = st.text[i]
        out[#out + 1] = {page = page, s = t.s, px = t.px,
                         font = t.font or "ui", col = t.col,
                         dim = t.dim or 1}
    end
    return out
end

-- Both shapes the menu is ever drawn in, because the scale differs between
-- them and a floor that holds on one and not the other is not a floor.
local SHAPES = {
    {"a monitor", 1440, 810, 1},
    {"a retina laptop", 2560, 1600, 2},
    {"a phone upright", 390, 844, 1},
}

local all = {}
for _, shape in ipairs(SHAPES) do
    for _, p in ipairs(PAGES) do
        for _, t in ipairs(runs(p[1], p[2], shape[2], shape[3], shape[4])) do
            t.shape, t.density = shape[1], shape[4]
            all[#all + 1] = t
        end
    end
end

-- Asked page by page rather than as one total. A total is a number that has to
-- be re-chosen every time a page leaves the menu, and it passes a fixture set
-- where one page draws nothing at all as long as the others are wordy enough.
-- What this ever wanted to know is that none of them comes up blank.
local blank = nil
for _, shape in ipairs(SHAPES) do
    for _, p in ipairs(PAGES) do
        local n = 0
        for _, t in ipairs(all) do
            if t.page == p[1] and t.shape == shape[1] then n = n + 1 end
        end
        if n < 4 then blank = p[1] .. " on " .. shape[1] .. ": " .. n end
    end
end
check("the menu draws something on every page and shape", not blank, blank)

-- --- 1. the floor ---------------------------------------------------------

do
    local worst, worst_at = 99, nil
    local under = 0
    for _, t in ipairs(all) do
        local a = t.col[4] * t.dim
        -- The card's own stand-down is not a legibility failure. A question
        -- takes the keys off the page behind it and the page says so by going
        -- almost out; nothing back there is meant to be read.
        if t.dim >= 1 then
            for _, g in ipairs(GROUNDS) do
                local r = contrast(over(t.col, a, g[2]), g[2])
                if r < floor_for(t.px, t.density) then
                    under = under + 1
                    if r < worst then
                        worst, worst_at = r, string.format(
                            "%q on %s, %s, %.3g pt, %.2f:1 on %s",
                            t.s, t.page, t.shape, t.px, r, g[1])
                    end
                end
            end
        end
    end
    check("every run of type clears WCAG AA on every ground it can land on",
          under == 0,
          under > 0 and (under .. " under the floor, worst " .. worst_at)
              or nil)
end

-- --- 2. the ladder --------------------------------------------------------

do
    local named = {}
    for name, pt in pairs(ui.TYPE) do named[pt] = name end
    local off, seen = {}, {}
    for _, t in ipairs(all) do
        -- Back out the scale the menu drew at. A window with room multiplies
        -- the whole thing by MENU_SCALE, so the ladder is in points and what
        -- lands in `state.text` is not.
        local zoom = t.shape == "a phone upright" and 1 or ui.MENU_SCALE
        local pt = t.px / (t.density * zoom)
        local rung = nil
        for v, name in pairs(named) do
            if math.abs(pt - v) < 0.01 then rung = name end
        end
        if rung then
            seen[rung] = true
        elseif not off[string.format("%.3g", pt)] then
            off[string.format("%.3g", pt)] = t.s
        end
    end
    local strays = {}
    for pt, s in pairs(off) do
        strays[#strays + 1] = string.format("%s pt (%q)", pt, s)
    end
    table.sort(strays)
    check("every size the menu sets is a rung of the ladder",
          #strays == 0, table.concat(strays, ", "))

    -- A rung nothing stands on is a rung to delete, which is the whole reason
    -- there are five of them and not fifteen.
    local unused = {}
    for name in pairs(ui.TYPE) do
        if not seen[name] then unused[#unused + 1] = name end
    end
    table.sort(unused)
    check("every rung of the ladder is used", #unused == 0,
          table.concat(unused, ", "))
end

-- --- 3. the faces ---------------------------------------------------------
--
-- Data is mono, things being read are the menu face. The test a person applies
-- is whether they would read it aloud as a sentence or look it up in a column,
-- and the test a file can apply is close enough: three words or more, with a
-- letter in every one of them, is a sentence.

do
    local function is_sentence(s)
        local words, letters = 0, 0
        for word in string.gmatch(s, "%S+") do
            words = words + 1
            if string.find(word, "%a%a") then letters = letters + 1 end
        end
        return words >= 3 and letters == words
    end

    local wrong, shown = 0, nil
    for _, t in ipairs(all) do
        if is_sentence(t.s) and t.font ~= "menu" then
            wrong = wrong + 1
            shown = shown or string.format("%q on %s", t.s, t.page)
        end
    end
    check("a sentence in the menu is set in the menu face", wrong == 0,
          wrong > 0 and (wrong .. " in the mono, e.g. " .. shown) or nil)
end

-- --- what the inks are worth ----------------------------------------------
--
-- The floor above is the check; this is the reason it passes, pinned so a
-- change to the palette says which of the two it broke. MUTE is the one with
-- no room to spare, which is why it exists: DIM, the color it replaced, is
-- worth 4.68:1 on the column and cannot survive being drawn on a lit row at
-- all.

do
    local WANT = {
        {"INK", pal.INK, 12.0}, {"READ", pal.READ, 7.0},
        {"MUTE", pal.MUTE, 4.5}, {"FRIEND", pal.FRIEND, 8.5},
        {"CHARGE_COL", pal.CHARGE_COL, 10.0}, {"HURT", pal.HURT, 4.5},
    }
    for _, e in ipairs(WANT) do
        local worst = 99
        for _, g in ipairs(GROUNDS) do
            worst = math.min(worst, contrast(e[2], g[2]))
        end
        check(string.format("%s reads on every ground in the menu", e[1]),
              worst >= e[3],
              string.format("%.2f:1, wanted %.1f", worst, e[3]))
    end

    -- A control's own boundary is what says a control is there, so it wants
    -- the 3:1 non-text contrast asks of one.
    check("a key's outline is findable against the column",
          contrast(pal.KEY_EDGE, COLUMN) >= 3.0,
          string.format("%.2f:1", contrast(pal.KEY_EDGE, COLUMN)))

    -- And the color it replaced is kept honest, so nobody puts it back.
    check("DIM could not have done MUTE's job",
          contrast(pal.DIM, GROUNDS[2][2]) < 4.5,
          string.format("%.2f:1 on a lit row", contrast(pal.DIM, GROUNDS[2][2])))
end

print(fails == 0 and "all type checks passed"
      or (fails .. " type checks failed"))
os.exit(fails == 0 and 0 or 1)
