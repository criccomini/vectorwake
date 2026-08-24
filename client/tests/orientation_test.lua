-- A game is landscape only.
--
--     lua5.1 client/tests/orientation_test.lua
--
-- The arena is laid out along the wide axis: an instrument in each top
-- corner, a thumb in each bottom one, and the fight in what is left between
-- the four. Stood on end there is no middle left, so a phone held upright
-- drew each of those over another with the game going on underneath. It is
-- not drawn at all now: one card asks for the phone to be turned, and the
-- HUD, the menu over it and both thumbs' controls wait for it.
--
-- The home menu is the other half of the rule and is checked here too,
-- because "in a game" is the whole of what this turns on and a change that
-- caught the home screen with it would take the phone's only portrait
-- surface away without anybody noticing.
--
-- Three things have to agree or the rule is worse than not having it: what
-- is drawn, what the menu flag says, and what a finger is tested against. A
-- control answering where nothing was drawn is the fault this interface has
-- already had, so the input path's own reading is measured rather than
-- assumed.

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

local layer = {n = 0}
local function noop(self) self.n = self.n + 1 end
for _, name in ipairs({"arc", "disc", "flush", "frame", "outline", "quad",
                       "reset", "ring", "ring_fade", "seg", "seg_fade",
                       "seg_flat", "skirt", "tri", "tri_fade", "halo",
                       "fan", "rect", "glow_band", "seg_glow"}) do
    layer[name] = noop
end

local harness = require("tests.ui_harness")
local ui, state = harness.install()
local frame = require("arena.frame")

-- --- which way round the window is -----------------------------------------

local function shape(w, h)
    state.n = 0
    ui.begin(layer, w, h, 1, true)
    return ui.landscape()
end

check("a phone on its side is landscape", shape(844, 390))
check("a phone stood on end is not", not shape(390, 844))
check("a desktop window is landscape", shape(1280, 800))
check("and one dragged narrower than it is tall is not",
      shape(600, 900) == false)
-- Square is landscape, because at that point the instruments have the room
-- they want and there is nothing to ask a player to do.
check("a square window counts as landscape", shape(700, 700))

-- The input path reads the same window and has to reach the same answer, or
-- a pad is tested against a layout that was never drawn.
check("the frame loop agrees on a phone on its side",
      frame.landscape({vw = 844, vh = 390}))
check("and on one stood on end",
      not frame.landscape({vw = 390, vh = 844}))
-- Before the first frame the engine has told nobody how big the window is.
-- Zero by zero is square, which keeps the answer off the card during the
-- frames where there is nothing to draw either way.
check("a window nothing has measured yet is not asking to be turned",
      frame.landscape({}))

-- --- the card that stands in its place -------------------------------------

local function card(w, h, touching)
    state.n = 0
    ui.begin(layer, w, h, 1, touching)
    ui.turn_card()
    ui.finish()
    local said = {}
    for k = 1, state.n do said[#said + 1] = state.text[k].s end
    return table.concat(said, " | ")
end

local phone = card(390, 844, true)
check("a phone is asked to be turned", phone:find("sideways") ~= nil, phone)
local desktop = card(600, 900, false)
check("a window is asked to be widened", desktop:find("[Ww]iden") ~= nil,
      desktop)
check("and both are told the game has not stopped without them",
      phone:find("still in it") and desktop:find("still in it"), phone)

-- Nothing behind the card is listening, so nothing behind it may be pressed.
check("the card leaves no hit box on the screen", #ui.hits == 0,
      tostring(#ui.hits) .. " boxes")

-- --- what the menu does about it -------------------------------------------

-- `frame.live` is the one place that decides whether the menu is up. Stubs
-- for the two things it asks: a connection and a ship count.
local net = {connected = true}
local sim = {ship_count = function() return 4 end}

local function menu_after(vw, vh, opts)
    opts = opts or {}
    local menu = {open = opts.open ~= false, home = false}
    local self = {vw = vw, vh = vh, online = true,
                  attract = opts.attract or false}
    frame.live(self, net, sim, menu)
    return menu
end

local playing = menu_after(390, 844)
check("the menu over a game shuts when the phone stands up",
      not playing.open and not playing.home)
check("and stays up when it is on its side", menu_after(844, 390).open)

-- The home menu is the whole exception. It is a page of reading with a rail
-- of tabs, and a page reads perfectly well in a column.
local home = menu_after(390, 844, {attract = true})
check("the home menu is left alone on a phone stood on end",
      home.open and home.home)
check("and on one on its side", menu_after(844, 390, {attract = true}).open)

-- Not connected at all is home too, and that is the state the client boots
-- in: a portrait phone must reach the menu from a cold start.
local cold = {open = false, home = false}
frame.live({vw = 390, vh = 844, online = false},
           {connected = false}, sim, cold)
check("a phone that has joined nothing yet gets the menu", cold.open)

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
