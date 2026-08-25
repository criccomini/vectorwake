-- The menu's destination marks, called through their extracted drawing
-- module. Each mark has an exact primitive signature so an absent mapping
-- cannot quietly draw the fallback information mark and still pass.

package.path = "client/?.lua;" .. package.path

local menu_marks = require("arena.ui_menu_marks")

local calls = {}
local function record(name, ...)
    calls[#calls + 1] = {name = name, n = select("#", ...), args = {...}}
end

local layer = {}
for _, name in ipairs({"disc", "fan", "frame", "outline", "ring", "seg",
                        "tri"}) do
    layer[name] = function(_, ...) record(name, ...) end
end

local palette = {BG = "background"}
function palette.a(col, alpha)
    return {source = col, alpha = alpha}
end

local draw = menu_marks.new({
    frame = {layer = layer, scale = 2},
    palette = palette,
    rect = function(...) record("rect", ...) end,
    ry = function(y, h) return 1000 - y - (h or 0) end,
    pilot_mark = function(...) record("pilot", ...) end,
    thumb = function(...) record("thumb", ...) end,
    rivet_mark = function(...) record("rivet", ...) end,
})

local function signature(kind)
    calls = {}
    draw(kind, 100, 200, 10, "ink", 6)
    local parts = {}
    for i, call in ipairs(calls) do
        parts[i] = call.name .. "/" .. call.n
    end
    return table.concat(parts, ","), calls
end

local function repeated(name, argc, count)
    local out = {}
    for i = 1, count do out[i] = name .. "/" .. argc end
    return table.concat(out, ",")
end

local discord = repeated("tri", 7, 66) .. "," .. repeated("outline", 4, 3)
local expected = {
    zones = "outline/4,disc/5,ring/6",
    pilot = "pilot/5",
    team = "seg/7,fan/2,outline/4,seg/7,fan/2,outline/4",
    settings = "seg/7,rect/5,seg/7,rect/5,seg/7,rect/5",
    controls = "rect/5,frame/6,rect/5,frame/6,rect/5,frame/6,rect/5,frame/6",
    about = "ring/6,disc/5,seg/7",
    discord = discord,
    leave = "outline/4,seg/7,tri/7",
    friends = "pilot/5,pilot/5",
    upgrades = "rivet/4",
    ship = "thumb/5",
}

local failures = 0
for _, kind in ipairs({"zones", "pilot", "team", "settings", "controls",
                        "about", "discord", "leave", "friends", "upgrades",
                        "ship"}) do
    local got = signature(kind)
    if got == expected[kind] then
        print("ok   " .. kind .. " mark")
    else
        failures = failures + 1
        print("FAIL " .. kind .. " mark: " .. got)
    end
end

local _, ship = signature("ship")
local ship_args = ship[1].args
if ship_args[1] ~= 100 or ship_args[2] ~= 200 or ship_args[3] ~= 6
   or ship_args[4] ~= "ink" or math.abs(ship_args[5] - 10 / 17) > 0.000001 then
    failures = failures + 1
    print("FAIL ship mark forwards hull, color, and scale")
else
    print("ok   ship mark forwards hull, color, and scale")
end

if failures > 0 then os.exit(1) end
