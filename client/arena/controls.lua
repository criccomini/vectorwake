-- Every control the game answers to, in one list, with the key it comes on.
--
-- Two things read this and they draw it differently. ui.lua sets it as a table
-- under H: the key, what it is, and a sentence. The menu's controls page sets
-- the same list as rows, which is where a key is changed.
--
-- Both are a keyboard's. A touchscreen used to read this list too, as label
-- and sentence with the key column dropped, and what those sentences named
-- was the pads: a page describing controls the thumb reading it was resting
-- on. The pads say what they are by being drawn, the stick writes its own
-- gesture around its rim, and the menu no longer offers the page on glass.
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

return {
    -- The rudder is two controls and one gesture. Splitting it is what
    -- rebinding costs: a pilot moving to the left hand needs left and right on
    -- separate keys, and a single row could only ever offer them as a pair.
    {id = "turn_left", name = "turn left", cat = "fly", keys = {"left"},
     what = "Turns your ship left."},
    {id = "turn_right", name = "turn right", cat = "fly", keys = {"right"},
     what = "Turns your ship right."},
    {id = "thrust", name = "thrust", cat = "fly", keys = {"up"},
     what = "Drives your ship forward."},
    -- A stance on glass rather than something held: a double tap on the
    -- stick's half sets it and another undoes it. The stick writes that around
    -- its own rim and turns amber while it is set, which is where a thumb
    -- reads it. See arena/touch.lua.
    {id = "reverse", name = "reverse", cat = "fly", keys = {"down"},
     what = "Drives your ship backward."},
    {id = "guns", name = "guns", cat = "gun", keys = {"d"},
     what = "Fires your rapid weapon."},
    {id = "bombs", name = "bombs", cat = "bomb", keys = {"a"},
     what = "Fires a heavy weapon that detonates on impact."},
    -- Two charge keys, and they are positions rather than weapons.
    --
    -- A kit carries two kinds of charge and the pilot chooses which, so what
    -- W spends is whatever they put in the first slot on the ship page. The
    -- keys used to be named for the weapons, on the argument that a pilot
    -- should not have to learn a second name for a thing the corner stack
    -- already calls by its own; that was true while every hull carried every
    -- kind and it stopped being true the moment the pair became a choice. A
    -- key named for a weapon that is not fitted is worse than one named for
    -- the slot it spends.
    --
    -- The corner stack still says what is in each, which is where a pilot
    -- reads it in a fight, and the ship page says which key each row is on.
    {id = "charge_1", name = "charge 1", cat = "charge", keys = {"w"},
     what = "Spends the first charge on your ship."},
    -- Q rather than S, which the calls took (decision 167). W and Q are the
    -- pair the charges were first dealt to, read across under the left hand.
    {id = "charge_2", name = "charge 2", cat = "charge", keys = {"q"},
     what = "Spends the second charge on your ship."},
    -- The calls: five things to say to your own side during a match, listed
    -- under the scoreboard while the key is down, and a digit says one. See
    -- decision 167.
    {id = "say", name = "call", cat = "say", keys = {"s"},
     what = "Lists the calls; a digit says one to your side."},
    {id = "multi", name = "multifire", cat = "multi", keys = {"tick"},
     what = "Fans your gun wider for more energy per shot."},
    {id = "map", name = "map", cat = "map", keys = {"m"},
     what = "Shows the whole arena instead of the radar."},
    -- The two that stepped a selection through the roster are gone with the
    -- board they stepped: the sheet is a panel of the menu, so the arrows
    -- that walk every other panel walk it.
    {id = "details", name = "players", cat = "players", keys = {"p"},
     what = "Lists everyone here and what they are worth."},
    {id = "help", name = "controls", cat = "help", keys = {"h"},
     what = "Shows this table."},
    -- Last, and the one row on the page that cannot move. Escape is how you
    -- leave every card, every page and this table, so a pilot who bound it to
    -- something else would have taken away the key they need to undo it.
    {id = "menu", name = "menu", cat = "menu", keys = {"esc"}, fixed = true,
     what = "Opens the menu."},
}
