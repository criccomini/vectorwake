-- The palette, in one place.
--
-- These are the values the hand-written web prototype used, carried over when
-- it was retired, so the game kept the look it had already been seen in.
-- Colors are {r, g, b, a} in 0..1 rather than vector4s: every one of them is
-- read inside a draw loop, and a table index is cheaper than a userdata field.
--
-- Two teams separated by hue *and* luminance, per docs/design/identity.md, so
-- the distinction survives colorblind vision.

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

-- The menu's other two inks, under INK.
--
-- Text in the menu draws at full alpha and says what it means with a color,
-- which is a rule these two exist to make possible. DIM is why: on the
-- column's ground it is worth 4.68:1, so it clears the 4.5 small type wants
-- with nothing left over, and every fraction of alpha laid on top of it lands
-- under the line. Thirty-three call sites laid one on, and a third of the type
-- in the menu was unreadable as a result. See docs/design/interface.md.
--
-- READ is what a sentence, a price or a detail is set in, at 9.81:1. MUTE is
-- the register under it, at 6.54:1, and is what names a group and what a row
-- you cannot use is written in. Both are measured on the three grounds a menu
-- row actually has: the column, a row under the pointer, and the row you are
-- already on. MUTE's worst of those is 4.75:1, so there is room to draw it
-- over a lit field and still be read.
--
-- READ carries PANEL_INK's value and not its name. That constant is hull
-- plating, drawn as fills at a fifth of its alpha, and one name doing two jobs
-- is how a change to a ship's panel lines would quietly move the type on the
-- settings page.
M.READ      = rgb(0x9fb6d4)
M.MUTE      = rgb(0x8593a9)

M.FRIEND    = rgb(0x4fd6ff)
M.ENEMY     = rgb(0xffa552)
-- The logo is a brand mark rather than a team indicator. Its more saturated
-- orange and cyan are held here so the mesh drawing matches the web assets
-- without changing the colors pilots use to identify sides in the arena.
M.LOGO_ORANGE = rgb(0xff9d22)
M.LOGO_CYAN   = rgb(0x27c5ed)
M.LOGO_GAP    = rgb(0x000000)
M.BOMB      = rgb(0xff5ea8)
M.WHITE     = rgb(0xffffff)

-- Violet is the burst's: its two dozen bolts sit on no hull's ladder, so they
-- share the wormhole's band, the one that already means "a place, not a
-- player". A charge is a thing you found whole and it carries none of your
-- add-ons, which is what puts it off the ramp.
--
-- Shrapnel was in this band too and does not belong in it. A fragment is a
-- bullet of the thrower's gun rung, damage and bouncing both, so it goes on
-- the ramp with everything else fired off a ladder. See world.weapons.
M.BURST     = rgb(0xc27bff)

M.BORDER    = rgb(0x1d2838)
M.BAR_EDGE  = rgb(0x22304a)
-- The outline of anything you can press, and the one edge in the interface
-- with a number to hit: a control's own boundary is what says a control is
-- there, so it wants 3:1 against what is beside it the way small type wants
-- 4.5. This is 3.97:1 on the column. A key cap wore DIM at 0.55 before, worth
-- 2.12, which left a button whose label was hard to read sitting in a box you
-- could not see either.
--
-- Rules between rows and divisions inside a panel keep BORDER. Those are
-- drawing rather than structure, and nothing has to find them.
M.KEY_EDGE  = rgb(0x55708f)
M.RADAR_BG  = rgb(0x060a10)
-- Terrain has to read as terrain at two pixels a tile. The old value was
-- #16243a on #070b12, which is a dark slate on a darker one: technically
-- present, invisible in practice.
M.RADAR_TILE= rgb(0x3f5878)
M.RADAR_SAFE= rgb(0x1d5f63)
M.RADAR_DOOR= rgb(0x7a4a2a)
M.BTN_BG    = rgb(0x0a0f18)

-- A wall's body is darker than it looks, because the light near an open face
-- brings it back up. One flat slate all the way through has no thickness in
-- it; near black at the core and lit at the rim, it does, and it is the same
-- idea as a hull lit at the bow.
M.WALL      = rgb(0x080d16)
M.WALL_EDGE = rgb(0x22344f)
M.WALL_LIT  = rgb(0x5b82b8)
-- Rock is warmer and grayer than anything built, so an asteroid field never
-- reads as architecture and a big one is never mistaken for an Anvil.
M.ROCK      = rgb(0x14131a)
M.ROCK_EDGE = rgb(0x8a8794)
M.ROCK_DARK = rgb(0x0d0c12)
M.ROCK_MID  = rgb(0x1d1a22)
M.ROCK_LIT  = rgb(0x2b252c)
M.ROCK_ORE  = rgb(0xa85f43)

-- A station is built from the wall palette but has enough room to name its
-- machinery. The cold line is service light, not team identity, and the warm
-- line is paint on a threshold rather than a projectile or a pilot.
M.STATION_BODY   = rgb(0x090f19)
M.STATION_PLATE  = rgb(0x111b2a)
M.STATION_RECESS = rgb(0x03060b)
M.STATION_COLD   = rgb(0x78a9c3)
M.STATION_WARM   = rgb(0xc78346)

-- A gravity well gets a band nothing else uses. Pink belongs to the bomb and
-- orange to a team; a wormhole wearing either is a wormhole people shoot at.
M.HOLE      = rgb(0xa06bff)
-- A door's own color, and the reason it is this one.
--
-- Doors used to be drawn in the wall's blue, deliberately: color belongs to
-- teams and to weapon classes, and a door wearing either is a door somebody
-- misreads under fire. That rule stands and this does not break it. Teams are
-- cyan and amber, weapons are pink and gold, and a door is green, which is a
-- band nothing else in the arena occupies. What it buys is that a shut door
-- and an open one differ in hue rather than only in brightness, which is the
-- difference you want to read at speed and across a starfield.
M.DOOR      = rgb(0x35e0a0)
M.DOOR_OPEN = rgb(0x1c8f6a)
-- Three depths of star. The old pair were #1b2740 and #121b2e on a #05070c
-- field, which is a dark slate on a darker one: present in the buffer,
-- invisible on the screen, and reported as a missing starfield. The near
-- layer has to be a point of light or the parallax has nothing to show.
M.STAR_NEAR = rgb(0x93a9c8)
M.STAR      = rgb(0x4a6089)
M.STAR_FAR  = rgb(0x2a3a58)

M.THRUST    = rgb(0xffbe78)
M.HURT      = rgb(0xff505a)

-- A hull's interior structure: plates, panel lines, the truss inside a
-- Lattice's arms. Neutral on purpose and the same on both teams, so the team
-- read stays on the silhouette where identity.md puts it. Drawn in the team
-- color instead, a ship looks cut from a single sheet of neon rather than
-- built out of parts.
M.PANEL_INK = rgb(0x9fb6d4)

-- The five stats, in the order the core defines them.
M.UPGRADES = {
    {name = "energy",   short = "NRG", col = rgb(0x7fe3a0)},
    {name = "recharge", short = "RCH", col = rgb(0x4fd6ff)},
    {name = "speed",    short = "SPD", col = rgb(0xffd166)},
    {name = "thrust",   short = "THR", col = rgb(0xff9a5c)},
    {name = "rotation", short = "ROT", col = rgb(0xc79bff)},
}

-- The six add-ons, in sim_mod order. They share one category in the menus and
-- are drawn onto the trigger they change, rather than presented as six separate
-- weapons.
--
-- Three lengths, for three places with three amounts of room. `short` is what
-- a shelf chip says, `name` labels a row, and `long` is for somewhere that is
-- explaining rather than reporting: the
-- hangar and the hover card in the corner, which exist because "prox"
-- teaches nobody what the round does. Only the ones whose short name is
-- jargon carry a `long`, and a caller that wants one falls back to `name`.
-- `short` is what a chip says, so it is the word rather than a code: a chip is
-- wide enough for one and three letters bought nothing. `name` is what the
-- rows and the shelf spell out.
M.MODS = {
    -- Spray, not multifire. What it does is put more where one went, and
    -- "multi" was the core's word for the mechanism rather than a name for
    -- the thing a pilot is buying.
    --
    -- It is a count of rounds rather than a rung of something, which is what
    -- makes it the one row on the ship page whose readout is a number and not
    -- a position: a spray of two is two rounds. It was two ladders, this and
    -- a "double barrel" that also meant more rounds, and nobody could say
    -- what the difference bought.
    {name = "spray",    short = "SPRAY"},
    {name = "bounce",   short = "BOUNCE"},
    {name = "prox",     short = "PROX", long = "proximity detonation"},
    {name = "shrapnel", short = "SHRAPNEL"},
    {name = "freeze",   short = "FREEZE"},
    -- Push, not repel. The core calls this one `SIM_MOD_PUSH` and the
    -- meta-layer prices it as "push"; only this table said repel, which is
    -- also the name of a charge, so a bomb wearing it and the charge in the
    -- next group along both read RPL. Off every arena's ladder for now.
    {name = "push",     short = "PUSH", long = "a shove welded onto a bomb"},
}
-- What a kill paid, drifting off the wreck that paid it, and the same green
-- the feed uses for a line about a kill of yours.
M.PAID      = rgb(0x8dffb0)
-- The feed's line about a kill you helped with: the same green, a step
-- darker. An assist is the lesser half of what PAID means, and a second
-- full-strength color in that corner would make two kinds of line equally
-- loud. Its own value rather than PAID at a lower alpha, because alpha in
-- the feed is spent on how old a line is, and a color that arrived faded
-- would read as a kill of yours from nine seconds ago.
M.ASSIST    = rgb(0x5aa874)
-- A friend who is in a game, on the friends page, and nothing else. Green
-- because green is what a light on a panel means by being lit, which is a
-- convention older than this game and not worth being clever about. Not
-- FRIEND: that cyan is the menu's cursor and the color of your own side, so a
-- dot wearing it would be the fourth thing on the page saying "here", and not
-- PAID, which is what a kill was worth and belongs to the feed. The mark is
-- solid where this is lit and a hollow ring where it is not, so the fact
-- survives a screen that shows the two of them as one grey.
M.ONLINE    = rgb(0x62cc35)
-- Charges: things you carry a count of and spend.
-- Display names for the charge-kind space the core can represent. A kit may
-- carry two kinds; the two slots above them are reserved for a zone that
-- ships more and have no decided names.
M.CHARGES = {
    {name = "repel", short = "RPL"},
    {name = "burst", short = "BST"},
    {name = "charge 3", short = "C3"},
    {name = "charge 4", short = "C4"},
}
M.CHARGE_COL = rgb(0xffd166)
-- What a pilot is worth. Its own color, because it is neither a team nor a
-- kind of upgrade: it is a price.
M.BOUNTY    = rgb(0xffe08a)
M.MOD_COL   = rgb(0x9df0ff)

-- A pilot on a run. Gold, and the only gold in the arena that moves: the two
-- ends of a shimmer, run between by `M.gleam` below.
--
-- Neither is a team color and neither is near one, which is the point. A
-- streak is the one fact on screen that is about a person rather than about a
-- side, so it has to read the same whichever side you are on and it must not
-- be mistaken for either.
M.STREAK    = rgb(0xffc23d)
M.STREAK_HI = rgb(0xfff3c4)

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

-- The shimmer itself: gold that travels between its two ends and back on a
-- clock, so a streak announces itself by moving in a picture where nothing
-- else in that hue does.
--
-- A raised cosine rather than a straight one. A linear sweep spends most of
-- its time in the middle, which reads as a color that cannot make its mind up;
-- weighting it toward the ends makes it read as a gleam crossing something.
--
-- `t` is seconds and needs no origin: any two callers a fraction apart are a
-- shimmer that is not quite in step, which is what a room full of them should
-- look like. `speed` is cycles a second.
function M.gleam(t, alpha, speed)
    local x = math.cos(t * (speed or 1.6) * 2 * math.pi)
    local k = x * x * (x > 0 and 1 or 0.55)
    return {
        M.STREAK[1] + (M.STREAK_HI[1] - M.STREAK[1]) * k,
        M.STREAK[2] + (M.STREAK_HI[2] - M.STREAK[2]) * k,
        M.STREAK[3] + (M.STREAK_HI[3] - M.STREAK[3]) * k,
        alpha or 1,
    }
end

-- --- a color a side ---------------------------------------------------------
--
-- Cyan and orange say "mine" and "not mine", which is the call a pilot makes
-- in a tenth of a second and the reason those two are separated by hue and by
-- luminance both. They do not say *which* not-mine, and in a room holding ten
-- sides that is a real question: three hulls converging is one thing if they
-- are one squad and another thing if they are three strangers.
--
-- So a side also gets a color of its own, generated rather than listed,
-- because a zone deals sides out at runtime and a table of eight would run
-- out. It is derived from the team byte alone, so every client agrees without
-- anything being sent.
--
-- Where it is *not* used matters as much. Hulls, plates and rounds keep the
-- two-color reading: this is worn by names and by the panels that talk about
-- people, which are read rather than glanced at. A hull that came in ten hues
-- would be a hull whose side takes a moment to work out, and the moment is
-- the whole game.
local function hsv(h, s, v)
    local c = v * s
    local hh = (h % 360) / 60
    local x = c * (1 - math.abs(hh % 2 - 1))
    local r, g, b
    if hh < 1 then r, g, b = c, x, 0
    elseif hh < 2 then r, g, b = x, c, 0
    elseif hh < 3 then r, g, b = 0, c, x
    elseif hh < 4 then r, g, b = 0, x, c
    elseif hh < 5 then r, g, b = x, 0, c
    else r, g, b = c, 0, x end
    local m = v - c
    return {r + m, g + m, b + m, 1}
end

-- The arc FRIEND sits in, kept clear so no side is issued a cyan: cyan is
-- reserved for yours, and an enemy wearing it is the one mistake this whole
-- scheme could make. FRIEND is 194 degrees, and forty-five degrees around it
-- is wide enough that nothing lands near.
local TEAM_GAP_LO, TEAM_GAP_HI = 172, 217
local TEAM_ARC = 360 - (TEAM_GAP_HI - TEAM_GAP_LO)
-- Golden angle, so consecutive bytes are far apart and the whole set stays
-- spread however many sides a room ends up holding. A hue wheel walked in
-- even steps only looks even for the count it was cut for.
local PHI = 0.6180339887498949
local team_cache = {}

-- How bright a color actually is, which is not what its value says. A hue
-- wheel walked at one saturation is not walked at one brightness: the eye
-- takes a fifth of its luminance from blue and seven tenths from green, so a
-- pure blue at full value is half the color a pure yellow is, and on a black
-- field it is the one nobody can read.
local function luma(c)
    local function lin(v)
        return v <= 0.04045 and v / 12.92 or ((v + 0.055) / 1.055) ^ 2.4
    end
    return 0.2126 * lin(c[1]) + 0.7152 * lin(c[2]) + 0.0722 * lin(c[3])
end

function M.team(t)
    t = t or 0
    local c = team_cache[t]
    if not c then
        local h = ((t + 1) * PHI % 1) * TEAM_ARC
        if h >= TEAM_GAP_LO then h = h + (TEAM_GAP_HI - TEAM_GAP_LO) end
        -- Hue is not enough on its own. Twelve of them spread over this arc
        -- sit eighteen degrees apart at the closest, which is plenty until
        -- the blues get walked toward white below and two of them arrive at
        -- the same pale. So saturation carries a second reading, three steps
        -- of it, and two sides near in hue land far apart in color.
        local s = ({0.66, 0.44, 0.30})[t % 3 + 1]
        c = hsv(h, s, 1)
        while luma(c) < 0.24 and s > 0.15 do
            s = s - 0.04
            c = hsv(h, s, 1)
        end
        team_cache[t] = c
    end
    return c
end

-- The rung ramp. One color a rung, and color on a round says nothing else:
-- the same four for a bullet and a bomb, for yours and for theirs.
--
-- There were three ramps before this, one per team plus one for bombs, with
-- hue carrying the owner and lightness the rung. Two things were wrong with
-- it. The rungs were ten units of color apart, which is not a call anybody
-- makes on a three-pixel object crossing the screen; and blending toward
-- white converged the teams as they climbed, so the rounds that matter most
-- were the ones hardest to tell apart, twenty units at the top against a
-- hundred at the bottom. It also put a rung 3 bomb on 0xffd166, which is the
-- charge color exactly, and a rung 4 bolt within seven of the HUD's own
-- text.
--
-- Green, yellow, orange, red: the one scale nobody has to be taught. Thirty
-- nine apart rung to rung, and thirty one clear of the nearest thing already
-- on screen. Payout green lies nearest rung 1 and charge gold nearest rung 2,
-- the price of borrowing a scale everybody already knows.
--
-- What it gives up is that a round no longer says whose it is. That is not a
-- side effect; it is what one ramp means. The sentence that used to close
-- this argument said every round was worth dodging in a free-for-all, and
-- the game stopped being one: it is 4v4 melee now, and the core never lands
-- a teammate's bullet (contact and push both skip the firer's side), so a
-- teammate's stream is noise this scheme asks a pilot to flinch at. Decision
-- 55 weighs that and keeps the one ramp: a blast is team-blind, so the class
-- that kills is worth dodging whoever threw it, and a three-pixel round
-- never had room for a second reading. Ships, names and plates still carry
-- the team.
--
-- Built once here rather than in the draw loop, which runs per projectile per
-- frame and must not allocate.
M.RUNG = {rgb(0x62cc35), rgb(0xf7dd0b), rgb(0xff7000), rgb(0xf42e3d)}

-- The color of a round at a rung, clamped, since a zone may hand out a
-- ladder longer than the ramp.
function M.rung(lvl)
    return M.RUNG[math.max(1, math.min(lvl + 1, #M.RUNG))]
end

return M
