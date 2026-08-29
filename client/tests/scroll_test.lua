-- A finger drags a menu page, and the cursor does not take it back.
--
--     lua5.1 client/tests/scroll_test.lua
--
-- `follow_cursor` keeps the row the arrows are on inside the window, which is
-- what a d-pad and a keyboard need. Held every frame it is a leash instead: a
-- page dragged by a thumb the cursor is not on snapped back on the very next
-- frame, so on glass the ship page could not be scrolled at all. A wheel got
-- away with it because a mouse hovers while it turns and a hover is the
-- cursor, so the row under the pointer was always on screen.
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

-- The ship page at a phone's measure, long enough to overflow it.
local function rows()
    local out = {}
    for i = 1, 14 do
        out[#out + 1] = {label = "hull " .. i, group = "ships",
                         sect = i == 1 and "ships" or nil,
                         detail = "a trade", hull = 0, ship = true,
                         bars = {0.2, 0.4, 0.6, 0.8, 1.0},
                         carries = {"gun spray 2", "repel 2"},
                         choice = i == 1 and 1 or 0, choices = 1,
                         index = #out + 1, pick = true}
    end
    return out
end

local function view(sel)
    return {depth = 2, sel = sel, rail = {}, rail_sel = 1, focus = "stage",
            home = true, closable = true, at = "hangar", ships = true,
            rows = rows()}
end

local function draw(sel)
    local st = package.loaded["arena.state"]
    st.n = 0
    ui.begin(layer, W, H, 1, false)
    ui.menu(view(sel))
    ui.finish()
end

-- The page has to overflow, or none of this means anything.
draw(1)
draw(1)
check("the page is longer than the window it is drawn in",
      ui.page_extent > ui.page_room and ui.page_room > 0,
      tostring(ui.page_extent) .. " in " .. tostring(ui.page_room))

-- A finger drags it. The cursor stays on the band, where it opened.
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
local walked = #rows()
draw(walked)
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
