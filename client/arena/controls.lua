-- Every control the game answers to, in one list, with the key it comes on.
--
-- Three things read this and they draw it differently. On a keyboard ui.lua
-- sets it as a table under H: the key, what it is, and a sentence. The menu's
-- controls page draws the same list as a grid of chips under a picture of the
-- keyboard, which is where a key is changed. On a touchscreen that page drops
-- to label and sentence, because there is no key column to draw and a
-- three-column table at the 350 points a menu panel is wide puts the sentence
-- back under the label it belongs to.
--
-- One list because there were two, and they drifted exactly the way two lists
-- of the same facts do: the phone's page was written before the map moved to
-- the dial and before anybody could be a gunner, so it went on describing a
-- game with neither in it. What a control does is one fact, and the device
-- decides how to say it, not what is true.
--
-- `id` is the name the press arrives under in `arena.script`, so it is not
-- free: adding a control here without a hand for it there is a row that says
-- a key does something it does not. `key` is where it starts, which a pilot
-- may move; arena/binds.lua holds where it actually is.
--
-- `cat` is which color the board draws the key in and which swatch the chip
-- carries. It groups rather than identifies, which is the reason the chips
-- exist at all: four charge keys share one color and the picture alone cannot
-- say which of them is which.
--
-- `pad` is how the control is worked by a thumb, or nil where a touchscreen
-- has no way to work it at all. Nil is a real answer and not a gap to fill in
-- later: reverse is deliberately absent on glass, and the controls table is
-- opened by a key that a phone does not have, since on a phone this list *is*
-- the page you are already reading.

return {
    -- The rudder is two controls and one gesture. Splitting it is what
    -- rebinding costs: a pilot moving to the left hand needs left and right
    -- on separate keys, and a single row could only ever offer them as a
    -- pair. `pad_name` puts them back together for the phone, where the stick
    -- covers both and there is nothing to separate.
    {id = "turn_left", name = "turn left", cat = "fly", key = "left",
     what = "Turns your ship left.",
     pad_name = "rudder",
     pad = "left thumb: point where you want the nose"},
    {id = "turn_right", name = "turn right", cat = "fly", key = "right",
     what = "Turns your ship right."},
    {id = "thrust", name = "thrust", cat = "fly", key = "up",
     what = "Drives your ship forward.",
     pad = "left thumb: push it away from the middle"},
    -- No thumb for this one. The stick points the nose, and a control that
    -- meant "the way you are not facing" would need a second gesture for a
    -- thing a pilot can do by turning round.
    {id = "reverse", name = "reverse", cat = "fly", key = "down",
     what = "Drives your ship backward."},
    {id = "guns", name = "guns", cat = "gun", key = "space",
     what = "Fires your rapid weapon.",
     pad = "the big pad on the right"},
    {id = "bombs", name = "bombs", cat = "bomb", key = "tab",
     what = "Fires a heavy weapon that detonates on impact.",
     pad = "the smaller pad beside the guns"},
    -- Not a weapon of its own and not a charge: the bomb trigger held
    -- differently. It sits next to bombs and wears the bomb's color for that
    -- reason, and it is the one control whose key is worked with another.
    {id = "mine_mod", name = "mine", cat = "bomb", key = "shift",
     what = "Held with the bomb key, lays a mine instead of throwing one.",
     pad = "tap the mine cell above the guns"},
    -- The charge keys are positions rather than weapons. Each one spends the
    -- next slot the hull you are in actually carries, so the first key is
    -- your repel on a ship that has one and your burst on a ship that does
    -- not. Naming them for what they usually spend is what the last version
    -- of this file did, and it went on saying "mine" for a month after mines
    -- stopped being a charge at all.
    {id = "charge_1", name = "charge 1", cat = "charge", key = "q",
     what = "Spends the first charge your ship carries.",
     pad = "tap its cell above the guns"},
    {id = "charge_2", name = "charge 2", cat = "charge", key = "w",
     what = "Spends the second charge your ship carries.",
     pad = "tap its cell above the guns"},
    {id = "charge_3", name = "charge 3", cat = "charge", key = "a",
     what = "Spends the third charge your ship carries."},
    {id = "charge_4", name = "charge 4", cat = "charge", key = "s",
     what = "Spends the fourth charge your ship carries."},
    {id = "multi", name = "multifire", cat = "multi", key = "tick",
     what = "Fans your gun wider for more energy per shot.",
     pad = "tap the fan cell to switch it off"},
    {id = "drone", name = "drop off", cat = "drone", key = "d",
     what = "Drops you off a ship you are riding.",
     pad = "your own row on the scoreboard carries DROP"},
    {id = "map", name = "map", cat = "map", key = "m",
     what = "Shows the whole arena instead of the radar.",
     pad = "tap the dial"},
    {id = "details", name = "players", cat = "players", key = "p",
     what = "Lists everyone here and what they are worth.",
     pad = "tap the scoreboard; a teammate's card offers ATTACH"},
    {id = "help", name = "controls", cat = "help", key = "h",
     what = "Shows this table."},
    -- Last, and the one row on the page that cannot move. Escape is how you
    -- leave every card, every page and this table, so a pilot who bound it to
    -- something else would have taken away the key they need to undo it.
    {id = "menu", name = "menu", cat = "menu", key = "esc", fixed = true,
     what = "Opens the menu.",
     pad = "tap MENU"},
}
