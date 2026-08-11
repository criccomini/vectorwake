-- Every control the game answers to, in one list.
--
-- Two things read this and they draw it differently. On a keyboard ui.lua
-- sets it as a table under H: the key, what it is, and a sentence. On a
-- touchscreen the menu's help page sets the same rows as label and sentence,
-- because there is no key column to draw and a three-column table at the 350
-- points a menu panel is wide puts the sentence back under the label it
-- belongs to.
--
-- One list because there were two, and they drifted exactly the way two lists
-- of the same facts do: the phone's page was written before the map moved to
-- the dial and before anybody could be a gunner, so it went on describing a
-- game with neither in it. What a control does is one fact, and the device
-- decides how to say it, not what is true.
--
-- `pad` is how the control is worked by a thumb, or nil where a touchscreen
-- has no way to work it at all. Nil is a real answer and not a gap to fill in
-- later: reverse is deliberately absent on glass, and the help table is
-- opened by a key that a phone does not have, since on a phone this list *is*
-- the page you are already reading.

return {
    {key = "\226\134\144 \226\134\146", name = "Rudder",
     what = "Turns your ship.",
     pad = "left thumb: point where you want the nose"},
    {key = "\226\134\145", name = "Thrusters",
     what = "Drives your ship forward.",
     pad = "left thumb: push it away from the middle"},
    -- No thumb for this one. The stick points the nose, and a control that
    -- meant "the way you are not facing" would need a second gesture for a
    -- thing a pilot can do by turning round.
    {key = "\226\134\147", name = "Reverse",
     what = "Drives your ship backward."},
    {key = "Space", name = "Guns", what = "Fires your rapid weapon.",
     pad = "the big pad on the right"},
    {key = "Tab", name = "Bombs",
     what = "Fires a heavy weapon that detonates on impact.",
     pad = "the smaller pad beside the guns"},
    {key = "Q", name = "Repel",
     what = "Pushes enemy fire and ships away from you.",
     pad = "tap its cell above the guns"},
    {key = "W", name = "Burst",
     what = "Fires bullets in every direction at once.",
     pad = "tap its cell above the guns"},
    {key = "A", name = "Mine",
     what = "Drops a mine that detonates when an enemy approaches.",
     pad = "tap its cell above the guns"},
    {key = "`", name = "Multifire",
     what = "Fans your gun wider for more energy per shot.",
     pad = "tap the fan cell to switch it off"},
    {key = "D", name = "Detach", what = "Drops you off a ship you are riding.",
     pad = "your own row on the scoreboard carries DROP"},
    {key = "M", name = "Map",
     what = "Shows the whole arena instead of the radar.",
     pad = "tap the dial"},
    {key = "P", name = "Players",
     what = "Lists everyone here and what they are worth.",
     pad = "tap the scoreboard; a teammate's card offers ATTACH"},
    {key = "H  ?", name = "Help", what = "Shows this table."},
    {key = "Esc", name = "Menu", what = "Opens the menu.",
     pad = "tap MENU"},
}
