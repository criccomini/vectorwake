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
-- the dial, so it went on describing a game without it. What a control does
-- is one fact, and the device decides how to say it, not what is true.
--
-- `id` is the name the press arrives under in `arena.script`, so it is not
-- free: adding a control here without a hand for it there is a row that says
-- a key does something it does not. `keys` is the chord it starts on, held
-- together and triggered by the last of them, which a pilot may move;
-- arena/binds.lua holds where it actually is.
--
-- `cat` is which color the board draws the key in and which swatch the chip
-- carries. It groups rather than identifies, which is the reason the chips
-- exist at all: two charge keys share one color and the picture alone cannot
-- say which of them is which.
--
-- `pad` is how the control is worked by a thumb, or nil where a touchscreen
-- has no way to work it at all. The controls table is opened by a key that a
-- phone does not have, since on a phone this list is the page already open.

return {
    -- The rudder is two controls and one gesture. Splitting it is what
    -- rebinding costs: a pilot moving to the left hand needs left and right
    -- on separate keys, and a single row could only ever offer them as a
    -- pair. `pad_name` puts them back together for the phone, where the stick
    -- covers both and there is nothing to separate.
    {id = "turn_left", name = "turn left", cat = "fly", keys = {"left"},
     what = "Turns your ship left.",
     pad_name = "rudder",
     pad = "left thumb: point where you want the nose"},
    {id = "turn_right", name = "turn right", cat = "fly", keys = {"right"},
     what = "Turns your ship right."},
    {id = "thrust", name = "thrust", cat = "fly", keys = {"up"},
     what = "Drives your ship forward.",
     pad = "left thumb: push it away from the middle"},
    -- This row carries no thumb sentence, because a phone has no reverse: the
    -- stick points where the nose should go and a push behind it is a turn, so
    -- there is no gesture to describe. See arena/touch.lua.
    {id = "reverse", name = "reverse", cat = "fly", keys = {"down"},
     what = "Drives your ship backward."},
    {id = "guns", name = "guns", cat = "gun", keys = {"space"},
     what = "Fires your rapid weapon.",
     pad = "the big pad on the right"},
    {id = "bombs", name = "bombs", cat = "bomb", keys = {"tab"},
     what = "Fires a heavy weapon that detonates on impact.",
     pad = "the smaller pad beside the guns"},
    -- Two charge keys, and they are positions rather than weapons.
    --
    -- A kit carries two kinds of charge and the pilot chooses which, so what
    -- Q spends is whatever they put in the first slot on the ship page. The
    -- keys used to be named for the weapons, on the argument that a pilot
    -- should not have to learn a second name for a thing the corner stack
    -- already calls by its own; that was true while every hull carried every
    -- kind and it stopped being true the moment the pair became a choice. A
    -- key named for a weapon that is not fitted is worse than one named for
    -- the slot it spends.
    --
    -- The corner stack still says what is in each, which is where a pilot
    -- reads it in a fight, and the ship page says which key each row is on.
    {id = "charge_1", name = "charge 1", cat = "charge", keys = {"q"},
     what = "Spends the first charge on your ship.",
     pad = "tap its fixed cell above the weapons"},
    {id = "charge_2", name = "charge 2", cat = "charge", keys = {"w"},
     what = "Spends the second charge on your ship.",
     pad = "tap its fixed cell above the weapons"},
    {id = "multi", name = "multifire", cat = "multi", keys = {"tick"},
     what = "Fans your gun wider for more energy per shot.",
     pad = "hold guns and slide up to toggle the fan"},
    {id = "map", name = "map", cat = "map", keys = {"m"},
     what = "Shows the whole arena instead of the radar.",
     pad = "tap the dial"},
    {id = "details", name = "players", cat = "players", keys = {"p"},
     what = "Lists everyone here and what they are worth.",
     pad = "tap the scoreboard to browse pilots"},
    {id = "player_prev", name = "previous player", cat = "players",
     keys = {"pageup"},
     what = "Shows Players and selects the previous pilot."},
    {id = "player_next", name = "next player", cat = "players",
     keys = {"pagedown"},
     what = "Shows Players and selects the next pilot."},
    {id = "help", name = "controls", cat = "help", keys = {"h"},
     what = "Shows this table."},
    -- Last, and the one row on the page that cannot move. Escape is how you
    -- leave every card, every page and this table, so a pilot who bound it to
    -- something else would have taken away the key they need to undo it.
    {id = "menu", name = "menu", cat = "menu", keys = {"esc"}, fixed = true,
     what = "Opens the menu.",
     pad = "tap MENU"},
}
