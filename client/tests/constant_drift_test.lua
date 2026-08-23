-- The numbers the client keeps a second copy of.
--
--     lua5.1 client/tests/constant_drift_test.lua
--
-- Some facts about this game are written down in more than one language. A
-- tile is sixteen pixels in the core's C, in the renderer's Lua and in the
-- radar's arithmetic; the radar reaches sixty tiles in the client, in the
-- zone that culls snapshots to it and in the bots that see by it; the rating
-- bands are a table in Rust and a table in Lua. Every one of those copies is
-- held to the others by a comment, and a comment is not a check.
--
-- So this reads the authoritative side out of the C, the Rust and the map
-- tool, the same way hull_fit_test reads collision extents out of
-- sim/src/baseline.c, and fails here rather than on somebody's screen. It is
-- deliberately not a suggestion about where the constants ought to live: it
-- is the guard that says when the copies have parted.

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

local function read(path)
    local f = assert(io.open(path, "r"), "cannot open " .. path)
    local s = f:read("*a")
    f:close()
    return s
end

-- --- the face the menu is set in --------------------------------------------
--
-- One of the two faces is not monospace, so how wide a word draws is a table
-- generated from the file it draws with. A gap in that table is a word
-- measured as the widest character it holds, which is a field wider than its
-- word and a caret past the end of a name, and neither is loud enough to
-- notice. See client/tools/font_advances.py.

local face = dofile("client/arena/menu_face.lua")
local gaps = {}
for c = 32, 126 do
    local a = face.adv[c]
    if type(a) ~= "number" or a <= 0 or a > 1.5 then
        gaps[#gaps + 1] = string.char(c)
    end
end
check("the menu's face measures every printable character", #gaps == 0,
      table.concat(gaps))
check("and knows what its widest one is",
      type(face.widest) == "number" and face.widest >= face.adv[109],
      tostring(face.widest))
-- Proportional, which is the whole reason the table exists: a face where
-- every letter is the same width needs one number, and this one is not.
check("and it is not the monospace it is measured against",
      math.abs(face.adv[105] - face.adv[109]) > 0.05,
      string.format("i %.3f, m %.3f", face.adv[105], face.adv[109]))

-- --- the sizes the core defines ---------------------------------------------

local simh = read("sim/include/sim/sim.h")
local function define(src, name)
    return tonumber(src:match("#define%s+" .. name .. "%s+(%-?%d+)"))
end

local TILE_PX = define(simh, "SIM_TILE_PX")
local MAP_TILES = define(simh, "SIM_MAP_TILES")
local MAX_CLASSES = define(simh, "SIM_MAX_CLASSES")
check("sim.h names a tile size", TILE_PX ~= nil)
check("sim.h names a map size", MAP_TILES ~= nil)
check("sim.h names a class count", MAX_CLASSES ~= nil)

local worldsrc = read("client/arena/world.lua")
check("world.lua's TILE is the core's tile",
      tonumber(worldsrc:match("local TILE = (%d+)")) == TILE_PX,
      "sim.h says " .. tostring(TILE_PX))
-- The backing array's width is folded into tile keys, while drawing stops at
-- the current map's declared bounds. A room can be much smaller than the
-- array that holds it.
check("world.lua keys tiles by the core's map width",
      worldsrc:match("ty %* " .. MAP_TILES .. " %+ tx") ~= nil,
      "expected ty * " .. MAP_TILES .. " + tx")
check("world.lua bounds terrain by the declared map size",
      worldsrc:find("local map_w, map_h = sim.map_size()", 1, true) ~= nil)

-- The hull count, which the menu clamps a saved hull against and the wire is
-- refused for exceeding.
local menusrc = read("client/arena/menu.lua")
local hullblock = menusrc:match("local HULLS = {(.-)\n}")
local hulls = 0
if hullblock then
    for _ in hullblock:gmatch('{"') do hulls = hulls + 1 end
end
check("the menu lists exactly the core's classes", hulls == MAX_CLASSES,
      "menu has " .. hulls .. ", sim.h says " .. tostring(MAX_CLASSES))

-- The add-ons, which the palette names by index against `sim_mod`. A table
-- short by one draws the last add-on as "add-on 6" and colors it by falling
-- off the end of the list, which is how the barrel slot arrived on screen the
-- first time it was bought.
local modblock = simh:match("typedef enum {(.-)} sim_mod;")
local MOD_COUNT = 0
if modblock then
    for line in modblock:gmatch("[^\n]+") do
        local name = line:match("^%s*(SIM_MOD_[%u_]+)")
        if name and name ~= "SIM_MOD_COUNT" then MOD_COUNT = MOD_COUNT + 1 end
    end
end
check("sim.h names its add-ons", MOD_COUNT > 0, tostring(MOD_COUNT))
local palsrc = read("client/arena/palette.lua")
local modtable = palsrc:match("M%.MODS = {(.-)\n}")
local named = 0
if modtable then
    for _ in modtable:gmatch("{name =") do named = named + 1 end
end
check("the palette names every add-on the core has", named == MOD_COUNT,
      "palette has " .. named .. ", sim.h says " .. tostring(MOD_COUNT))

-- --- the radar's reach ------------------------------------------------------
--
-- The dial and bots use the sixty-tile radar reach. The zone adds the same
-- twenty-four-tile arrival margin the renderer keeps around that reach.

local uisrc = read("client/arena/ui.lua")
local deliveryrs = read("server/src/delivery.rs")
local aisrc = read("server/src/ai.rs")
local arenasrc = read("client/arena/arena.script")

-- The kit reaches the room on arrival, not only when a point is spent.
--
-- The room deals a starter kit to any seat wearing nothing and never asks the
-- meta-layer for a stored one, so this send is the whole of how a built kit
-- gets flown. Without it a pilot who had spent an evening in the hangar flew
-- the default until the next time they moved a point, which is silent: the
-- ship looks right and fires the wrong number of rounds.
check("the client sends its kit when a seat is taken",
      arenasrc:match("menu%.open_kit%(menu%.class%)%s*\n%s*net%.set_kit") ~= nil,
      "arena.script no longer sends a kit on arrival")

local reach = tonumber(worldsrc:match("local RADAR_TILES = (%d+)"))
check("world.lua names a radar reach", reach ~= nil)
check("the dial spans the same reach",
      tonumber(uisrc:match("local SPAN = (%d+) %* " .. TILE_PX)) == reach,
      "world.lua says " .. tostring(reach))
local fair = tonumber(deliveryrs:match("const FAIR_INTEREST: i32 = (%d+) %*"))
local slack = tonumber(worldsrc:match("local RADAR_SLACK = (%d+)"))
check("the zone filters at radar reach plus arrival margin",
      fair == reach + slack,
      "client says " .. tostring(reach + slack) .. ", zone says " .. tostring(fair))
check("a bot sees the same reach",
      tonumber(aisrc:match("pub const SIGHT: f32 = (%d+)%.0 %* " ..
                           TILE_PX .. "%.0")) == reach,
      "world.lua says " .. tostring(reach))

-- The slack the static terrain window keeps beyond the radar has to stay
-- wider than the step that window moves in, or terrain blinks in at the edge
-- between one rebuild and the next. Both sides are literals in different
-- files, tied by a comment.
local step = tonumber(arenasrc:match("STATIC_STEP = (%d+)"))
check("the terrain window's slack clears its step",
      slack and step and slack > step,
      "slack " .. tostring(slack) .. ", step " .. tostring(step))

-- --- what kind of solid a solid tile is --------------------------------------
--
-- The renderer draws rocks and stations from these, and an unknown variant
-- falls through to a plain wall without complaining, so a renumbering here is
-- silent at build time and at run time both.
--
-- Three files carry the numbering now. sim.h is where it is defined, and the
-- other two copy it because neither Lua nor a browser can read a C header: the
-- renderer, which turns a variant into a picture, and the map editor, which is
-- the thing that writes one in the first place. An editor a rung out of step
-- with the renderer draws a station and saves a rock.

-- The renderer declares these singly and in pairs, so both shapes are read.
-- [%w_] rather than %w: Lua's %w is letters and digits and stops at the
-- underscore in the middle of a name like V_ROCK_BODY.
local variants = {}
for name, val in worldsrc:gmatch("local (V_[%w_]+) = (%d+)") do
    variants[name] = tonumber(val)
end
for a, b, x, y in worldsrc:gmatch("local (V_[%w_]+), (V_[%w_]+) = (%d+), (%d+)") do
    variants[a], variants[b] = tonumber(x), tonumber(y)
end

-- The editor declares them in runs on one line, which one pattern covers.
local editor = read("deploy/admin/maps.js")
local paints = {}
for name, val in editor:gmatch("(S_[%w_]+) = (%d+)") do
    paints[name] = tonumber(val)
end

for _, name in ipairs({"BORDER", "ROCK_A", "ROCK_B", "ROCK_BIG",
                       "ROCK_BODY", "STATION", "STATION_BODY"}) do
    local want = define(simh, "SIM_SOLID_" .. name)
    check("world.lua's V_" .. name .. " is the core's",
          want ~= nil and variants["V_" .. name] == want,
          "sim.h says " .. tostring(want) ..
              ", world.lua " .. tostring(variants["V_" .. name]))
    check("the editor's S_" .. name .. " is the core's",
          want ~= nil and paints["S_" .. name] == want,
          "sim.h says " .. tostring(want) ..
              ", maps.js " .. tostring(paints["S_" .. name]))
end

-- The editor offers one paint per kind of solid, so a variant added to the
-- core and drawn by the client is a variant somebody can actually place. The
-- two body tiles are not paints of their own: they are what a stamp fills in
-- around the corner that carries the picture.
for _, name in ipairs({"S_WALL", "S_BORDER", "S_ROCK_A", "S_ROCK_B",
                       "S_ROCK_BIG", "S_STATION"}) do
    check("the editor can place " .. name,
          editor:find("v: " .. name, 1, true) ~= nil)
end

-- --- the rating bands -------------------------------------------------------
--
-- Asked of the client rather than read out of it: the wire carries a raw
-- rating and a count of games and the client decides the band, so the band is
-- behaviour and can be probed. The server's table is the authority.

local ratingrs = read("server/src/rating.rs")
local provisional = tonumber(ratingrs:match("PROVISIONAL_GAMES: u32 = (%d+)"))
check("rating.rs names a provisional count", provisional ~= nil)

local bands = {}
for name, floor in ratingrs:gmatch('%("(%a+)",%s*([%w_:%.%-]+)%),') do
    bands[#bands + 1] = {name = name, floor = tonumber(floor)}
end
check("rating.rs names five bands", #bands == 5, "found " .. #bands)

_G.websocket = {DATA_TYPE_BINARY = 1, EVENT_CONNECTED = "connected",
                EVENT_MESSAGE = "message", EVENT_DISCONNECTED = "disconnected",
                EVENT_ERROR = "error", connect = function() return {id = 1} end,
                send = function() end, disconnect = function() end}
_G.sys = {get_config_string = function(_, d) return d or "" end,
          get_save_file = function() return "/dev/null" end,
          save = function() return true end, load = function() return {} end,
          get_engine_info = function() return {version = "test"} end}
_G.http = {request = function() end}
_G.json = {encode = function() return "{}" end, decode = function() return {} end}
_G.timer = {delay = function() end}
_G.sim = setmetatable({}, {__index = function() return function() return 0 end end})

local net = require("arena.net")

check("a pilot below the provisional count is placing",
      net.tier(1500, provisional - 1) == "placing",
      tostring(net.tier(1500, provisional - 1)))
check("a pilot at the provisional count has a band",
      net.tier(1500, provisional) ~= "placing")

-- Each band's floor names that band, and a hair under it names the one below.
for i, b in ipairs(bands) do
    if b.floor then
        check("rating " .. b.floor .. " is " .. b.name,
              net.tier(b.floor, provisional) == b.name,
              "client says " .. tostring(net.tier(b.floor, provisional)))
        local below = bands[i - 1]
        if below then
            check("just under " .. b.floor .. " is " .. below.name,
                  net.tier(b.floor - 1, provisional) == below.name,
                  "client says " ..
                      tostring(net.tier(b.floor - 1, provisional)))
        end
    else
        -- The bottom band is unbounded below, so there is no rating without a
        -- name. Anything beneath the next floor up belongs to it.
        check("the bottom band is " .. b.name,
              net.tier(-100000, provisional) == b.name,
              "client says " .. tostring(net.tier(-100000, provisional)))
    end
end

if fails > 0 then
    print(fails .. " failed")
    os.exit(1)
end
print("all ok")
