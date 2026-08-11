-- Pilot call signs.
--
-- Nobody types a name. A player is flying inside a second with something that
-- reads as belonging to this game rather than as a placeholder, and the one
-- device where typing is genuinely awkward -- a phone, a console -- never has
-- to ask. Consoles will hand us the platform's own name when we get there,
-- which is what they expect and what certification generally requires.
--
-- The words are in the roster's register but share none of its names, so a
-- pilot is never mistaken for one of the eight AI regulars.

local M = {}

local WORDS = {
    "Vesper", "Talon", "Corvid", "Ember", "Quill", "Solstice",
    "Zephyr", "Harrow", "Lumen", "Basalt", "Nimbus", "Cobalt",
    "Fathom", "Verge", "Auric", "Sleet", "Pike", "Marrow",
    "Torrent", "Beacon", "Cinder", "Drift", "Halyard", "Ingot",
    "Jetty", "Kiln", "Lantern", "Mistral", "Noctis", "Orbit",
    "Plume", "Quarry", "Rill", "Sextant", "Thistle", "Umber",
}

-- Its own generator rather than math.random, which the arena seeds to a fixed
-- value. A name has to differ between two tabs opened a second apart, and
-- anything drawn from a fixed seed is the same name every time.
local seed = 0

local function next_rand()
    seed = (seed * 1103515245 + 12345) % 2147483648
    return seed / 2147483648
end

function M.seed(n)
    seed = math.floor(n) % 2147483648
    next_rand()
end

-- 36 words against 90 numbers: enough that a full zone rarely collides, and
-- the server suffixes the ones that do.
function M.generate()
    local w = WORDS[math.floor(next_rand() * #WORDS) + 1]
    return w .. " " .. tostring(10 + math.floor(next_rand() * 90))
end

return M
