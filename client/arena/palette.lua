-- The palette, in one place.
--
-- These are the values the web prototype in `client-web/` uses, because that
-- page is what the game has actually been looked at in and the production
-- client has no business looking like a different game. Colours are
-- {r, g, b, a} in 0..1 rather than vector4s: every one of them is read inside
-- a draw loop, and a table index is cheaper than a userdata field.
--
-- Two teams separated by hue *and* luminance, per docs/design/identity.md, so
-- the distinction survives colourblind vision.

local function rgb(hex, a)
    return {
        math.floor(hex / 65536) % 256 / 255,
        math.floor(hex / 256) % 256 / 255,
        hex % 256 / 255,
        a or 1,
    }
end

local M = {rgb = rgb}

M.BG        = rgb(0x05070c)
M.INK       = rgb(0xdfe9f5)
M.DIM       = rgb(0x6c7a90)
M.FRIEND    = rgb(0x4fd6ff)
M.ENEMY     = rgb(0xffa552)
M.BOMB      = rgb(0xff5ea8)
M.WHITE     = rgb(0xffffff)

M.PANEL     = rgb(0x05080e, 0.72)
M.BORDER    = rgb(0x1d2838)
M.BAR_BG    = rgb(0x121a26)
M.BAR_EDGE  = rgb(0x22304a)
M.RADAR_BG  = rgb(0x060a10)
-- Terrain has to read as terrain at two pixels a tile. The old value was
-- #16243a on #070b12, which is a dark slate on a darker one: technically
-- present, invisible in practice.
M.RADAR_TILE= rgb(0x3f5878)
M.RADAR_GRID= rgb(0x141f30)
M.RADAR_SAFE= rgb(0x1d5f63)
M.RADAR_DOOR= rgb(0x7a4a2a)
M.BTN_BG    = rgb(0x0a0f18)
M.BTN_SEL   = rgb(0x0d1826)

M.WALL      = rgb(0x0d1726)
M.WALL_EDGE = rgb(0x22344f)
-- Three depths of star. The old pair were #1b2740 and #121b2e on a #05070c
-- field, which is a dark slate on a darker one: present in the buffer,
-- invisible on the screen, and reported as a missing starfield. The near
-- layer has to be a point of light or the parallax has nothing to show.
M.STAR_NEAR = rgb(0x93a9c8)
M.STAR      = rgb(0x4a6089)
M.STAR_FAR  = rgb(0x2a3a58)

M.THRUST    = rgb(0xffbe78)
M.HURT      = rgb(0xff505a)

-- The five stats, in the order the core defines them.
M.UPGRADES = {
    {name = "energy",   short = "NRG", col = rgb(0x7fe3a0)},
    {name = "recharge", short = "RCH", col = rgb(0x4fd6ff)},
    {name = "speed",    short = "SPD", col = rgb(0xffd166)},
    {name = "thrust",   short = "THR", col = rgb(0xff9a5c)},
    {name = "rotation", short = "ROT", col = rgb(0xc79bff)},
}

-- The six add-ons, in sim_mod order. One colour for all of them and one for
-- a level: a green's colour says what *kind* of thing it is, and its shape
-- says nothing, so the eye sorts the map into "stat", "level", "add-on"
-- rather than into nineteen things it has to learn.
M.MODS = {
    {name = "multi",    short = "MUL"},
    {name = "bounce",   short = "BNC"},
    {name = "prox",     short = "PRX"},
    {name = "shrapnel", short = "SHR"},
    {name = "freeze",   short = "FRZ"},
    {name = "repel",    short = "RPL"},
}
M.LEVEL_COL = rgb(0xff7ba8)
M.MOD_COL   = rgb(0x9df0ff)

-- What a green of this type is: its colour, and what the feed calls it.
-- The prize space is flat and the core hands out an index into it.
function M.prize(kind)
    local u = M.UPGRADES[kind + 1]
    if u then return u.col, u.name end
    local t = kind - #M.UPGRADES
    if t < 2 then
        return M.LEVEL_COL, (t == 0 and "gun level" or "bomb level")
    end
    t = t - 2
    local m = M.MODS[t % #M.MODS + 1]
    local trig = (t < #M.MODS) and "gun " or "bomb "
    return M.MOD_COL, trig .. (m and m.name or "?")
end

-- A copy at a different alpha. Draw code asks for these constantly and must
-- never mutate the shared table to get one.
function M.a(col, alpha)
    return {col[1], col[2], col[3], alpha}
end

-- A copy scaled toward white, for the hot core of a bright thing.
function M.hot(col, k, alpha)
    return {
        col[1] + (1 - col[1]) * k,
        col[2] + (1 - col[2]) * k,
        col[3] + (1 - col[3]) * k,
        alpha or col[4],
    }
end

return M
