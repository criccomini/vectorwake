-- A finger drags a menu page, and the cursor does not take it back.
--
--     lua5.1 client/tests/scroll_test.lua
--
-- The settings page is the one page in the column long enough to need this: it
-- climbs off its own stop and stops under the clock band, and on a phone the
-- rows run past what that leaves. A wheel and a thumb both move it through
-- `ui.page_scroll`, and the panel clamps that to what it has to give every
-- time it draws.
--
-- The follow keeps the row the arrows are on inside the window, which is what
-- a d-pad and a keyboard need. Held every frame it is a leash instead: a page
-- dragged by a thumb the cursor is not on snapped back on the very next frame,
-- so on glass the page could not be scrolled at all. A wheel got away with it
-- because a mouse hovers while it turns and a hover is the cursor, so the row
-- under the pointer was always on screen.
--
-- What is checked here is that the page moves and stays moved while nothing
-- moves the cursor, and that the arrows still drag it when they do.

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

local W, H = 390, 844
local harness = require("tests.ui_harness")
local layer = harness.layer()
local ui = harness.install()

-- Settings at a phone's measure, longer than the room the column leaves it.
local ROWS = 24
local function rows()
    local out = {}
    for i = 1, ROWS do
        out[#out + 1] = {label = "setting " .. i, detail = "a value",
                         choice = 1, choices = 3, index = i, pick = true}
    end
    return out
end

-- The column with the settings stop holding its page open, which is the one
-- shape here that scrolls: the side stop opens a list of three, and the bare
-- column is three rows over a key.
local function view()
    return {
        open = true, at = "settings", page = "settings",
        stops = {
            {stop = "leave", label = "leave", value = "to the stands"},
            {stop = "settings", label = "settings", mark = "settings",
             open = true},
            {stop = "side", label = "side", value = "Pylon", named = true},
        },
        rows = rows(),
    }
end

-- One frame with the cursor standing on a row, which is where the arrows leave
-- it. `sel` of nil is a hand that has touched nothing.
local function draw(sel)
    local st = package.loaded["arena.state"]
    st.n = 0
    ui.col_sel = sel and "menu_row" or nil
    ui.col_sel_value = sel
    ui.begin(layer, W, H, 1, false)
    ui.menu(view())
    ui.finish()
end

-- The page has to overflow, or none of this means anything. The panel keeps
-- its extent to itself, so the overflow is read back off the clamp instead: a
-- scroll past the end comes back at the end, and where it lands is how far
-- there was to go.
ui.page_scroll = 1e6
draw(nil)
local reach = ui.page_scroll
local _, _, _, room = ui.page_span()
check("the page is longer than the window it is drawn in",
      reach > 0 and room > 0,
      tostring(reach) .. " to go in " .. tostring(room))

-- A finger drags it. The cursor stays on the row it opened on.
draw(1)
draw(1)
ui.page_scroll = 120
draw(1)
check("a drag moves the page", ui.page_scroll == 120,
      tostring(ui.page_scroll))
-- And the next frame, with nothing having moved the cursor, leaves it there.
draw(1)
draw(1)
check("and the next frame leaves it where the finger put it",
      ui.page_scroll == 120, tostring(ui.page_scroll))

-- The arrows still drag the page, which is the whole reason the follow
-- exists: a cursor walked off the bottom takes the window with it.
draw(ROWS)
check("a cursor moved onto a row below the fold brings the page to it",
      ui.page_scroll > 120, tostring(ui.page_scroll))

-- And back up.
draw(1)
check("and back up when it walks the other way", ui.page_scroll == 0,
      tostring(ui.page_scroll))

if fails > 0 then
    print(("\n%d check(s) failed"):format(fails))
    os.exit(1)
end
print("\nall good")
