-- The Vectorwake mark, everywhere it exists.
--
--     lua5.1 client/tests/logo_test.lua
--
-- client/web/logo.svg is the canonical transparent vector. This test holds
-- the game mesh, loading screen, web pages, admin panel, social art, Discord
-- icon, favicons, and embedded install assets to the same geometry.

package.path = "client/?.lua;" .. package.path

local fails = 0
local function check(name, ok, detail)
    if ok then
        print("ok   " .. name)
    else
        fails = fails + 1
        print("FAIL " .. name .. (detail and (": " .. detail) or ""))
    end
end

local function read_file(path)
    local fh = assert(io.open(path, "rb"), "cannot read " .. path)
    local body = fh:read("*a")
    fh:close()
    return body
end

local function has(body, text)
    return body:find(text, 1, true) ~= nil
end

local function count(body, text)
    local n, at = 0, 1
    while true do
        local found = body:find(text, at, true)
        if not found then return n end
        n, at = n + 1, found + #text
    end
end

local ORANGE = "M42 0L84 67L66 78L42 53L18 78L0 67Z"
local CYAN = "M0 67L18 78L42 53L66 78L84 67L60 103L42 74L24 103Z"
local GAP = "M0 67L18 78L42 53L66 78L84 67"

local logo = read_file("client/web/logo.svg")
check("the canonical logo has an 84 by 104 view box",
      has(logo, 'viewBox="0 0 84 104"'))
check("the canonical logo has no background tile",
      not has(logo, "M0 0H512V512H0Z"))
check("the canonical logo carries the approved shapes",
      has(logo, ORANGE) and has(logo, CYAN) and has(logo, GAP))
check("the canonical logo carries the approved colors and gap",
      has(logo, '#ff9d22') and has(logo, '#27c5ed')
      and has(logo, 'stroke="#000"') and has(logo, 'stroke-width="3"')
      and has(logo, 'stroke-linecap="square"')
      and has(logo, 'stroke-linejoin="miter"'))

local icon = read_file("client/web/icon.svg")
local favicon = read_file("client/web/favicon.svg")
check("the app tile carries the canonical mark",
      has(icon, ORANGE) and has(icon, CYAN) and has(icon, GAP)
      and has(icon, "M0 0H512V512H0Z"))

-- The favicon and the app tile were the same file until the favicon lost its
-- background. They are two drawings now, and the pair of checks below is what
-- keeps that from meaning two marks.
--
-- The tile stays opaque because it is a tile: Discord masks it to a circle and
-- the installed-app icons composite on it, and either one against transparency
-- shows whatever is behind it through the middle of the ship. A favicon has the
-- opposite job. It sits in a tab strip whose color is the browser's business
-- and changes with the reader's theme, so #05070c there is a dark square around
-- the mark rather than an absence of one.
--
-- Same framing, same paths, same colors: the favicon is the tile's own
-- translate and scale with the tile path taken out.
check("every SVG favicon is the same drawing",
      favicon == read_file("deploy/site/favicon.svg")
      and favicon == read_file("deploy/admin/favicon.svg"))
check("the favicon carries the canonical mark, framed like the tile",
      has(favicon, ORANGE) and has(favicon, CYAN) and has(favicon, GAP)
      and has(favicon, '#ff9d22') and has(favicon, '#27c5ed')
      and has(favicon, 'stroke="#000"')
      and has(favicon, 'transform="translate(84.5 44) scale(4.0833333333)"')
      and has(icon, 'transform="translate(84.5 44) scale(4.0833333333)"'))
check("the favicon has no background tile",
      not has(favicon, "M0 0H512V512H0Z"))

-- The separator is a stroke centered on the seam between the two fills, and the
-- seam's ends are the mark's own outer corners, so half its width lands outside
-- the silhouette there. The tile hid that; transparency does not, and without
-- the clip the favicon grows a black spur off each shoulder. Clipping to the
-- two fills is what keeps the drawn shape equal to the mark.
check("the favicon clips its separator to the mark",
      has(favicon, 'clipPathUnits="userSpaceOnUse"')
      and has(favicon, 'clip-path="url(#mark)"'))

local site_pages = {
    "deploy/site/index.html",
    "deploy/site/privacy.html",
    "deploy/site/terms.html",
    "deploy/site/retention.html",
    "deploy/site/delete.html",
    "deploy/site/support.html",
    "deploy/site/pilot.html",
    "deploy/site/pilots.html",
}
for _, path in ipairs(site_pages) do
    local page = read_file(path)
    check(path .. " uses the canonical header and footer mark",
          count(page, 'class="mark-orange" d="' .. ORANGE .. '"') == 2
          and count(page, 'class="mark-cyan" d="' .. CYAN .. '"') == 2
          and count(page, 'class="mark-gap" d="' .. GAP .. '"') == 2)
end

local site_css = read_file("deploy/site/site.css")
check("the public mark styles use the approved treatment",
      has(site_css, ".mark-orange") and has(site_css, "#ff9d22")
      and has(site_css, ".mark-cyan") and has(site_css, "#27c5ed")
      and has(site_css, ".mark-gap") and has(site_css, "stroke-width: 3")
      and has(site_css, "stroke-linecap: square"))

local admin_page = read_file("deploy/admin/index.html")
local admin_css = read_file("deploy/admin/admin.css")
check("the admin header uses the canonical mark",
      count(admin_page, 'class="mark-orange" d="' .. ORANGE .. '"') == 1
      and count(admin_page, 'class="mark-cyan" d="' .. CYAN .. '"') == 1
      and count(admin_page, 'class="mark-gap" d="' .. GAP .. '"') == 1)
check("the admin mark styles use the approved treatment",
      has(admin_css, "#ff9d22") and has(admin_css, "#27c5ed")
      and has(admin_css, "stroke-width: 3")
      and has(admin_css, "stroke-linecap: square"))

for _, spec in ipairs({
    {"the social card", "deploy/site/share-card.svg"},
    {"the README banner", "docs/banner.svg"},
}) do
    local body = read_file(spec[2])
    check(spec[1] .. " uses the canonical mark",
          has(body, ORANGE) and has(body, CYAN) and has(body, GAP)
          and has(body, "#ff9d22") and has(body, "#27c5ed"))
end

-- Record only the mesh primitive the logo uses. The rest of the layer is
-- present so ui.lua can initialize normally without a renderer.
local tris = {}
local layer = {}
local function noop() end
for _, name in ipairs({"arc", "disc", "flush", "frame", "halo", "outline",
                       "quad", "rect", "reset", "ring", "seg", "seg_fade",
                       "seg_flat", "skirt", "tri_fade", "fan"}) do
    layer[name] = noop
end
layer.tri = function(_, x1, y1, x2, y2, x3, y3, col)
    tris[#tris + 1] = {x1, y1, x2, y2, x3, y3, col = col}
end

_G.sim = setmetatable({}, {__index = function()
    return function() return 0 end
end})
package.loaded["arena.state"] = {text = {}, n = 0, version = 0}
package.loaded["arena.touch"] = {
    layout = function() return {charge = {}} end,
    used = false,
}
package.loaded["arena.world"] = {
    build_overview = noop,
    forget_overview = noop,
    overview = function() return {grid = 0} end,
    radar_tiles = {},
    radar_safe = {},
    radar_doors = {},
    HULLS = setmetatable({}, {__index = function()
        return {poly = {0, 0, 1, 1, 2, 0}, mid = 0}
    end}),
}

local pal = require("arena.palette")
local ui = require("arena.ui")
ui.begin(layer, 512, 512, 1, false, 0)
ui.logo(256, 256, 104, 1, true)
ui.finish()

local function same_color(a, b)
    for i = 1, 4 do
        if math.abs(a[i] - b[i]) > 0.000001 then return false end
    end
    return true
end

local orange_n, cyan_n, gap_n = 0, 0, 0
for _, tri in ipairs(tris) do
    if same_color(tri.col, pal.LOGO_ORANGE) then orange_n = orange_n + 1 end
    if same_color(tri.col, pal.LOGO_CYAN) then cyan_n = cyan_n + 1 end
    if same_color(tri.col, pal.LOGO_GAP) then gap_n = gap_n + 1 end
end
check("the game logo is the complete 18-triangle mesh",
      #tris == 18, "triangles: " .. #tris)
check("the game mesh has every colored face and separator triangle",
      orange_n == 4 and cyan_n == 6 and gap_n == 8,
      string.format("orange %d, cyan %d, gap %d", orange_n, cyan_n, gap_n))
check("the game logo keeps the canonical aspect ratio",
      math.abs(ui.logo_width(104) - 84) < 0.000001)

local function triangle_span()
    local x0, x1 = math.huge, -math.huge
    for _, tri in ipairs(tris) do
        for i = 1, 6, 2 do
            x0 = math.min(x0, tri[i])
            x1 = math.max(x1, tri[i])
        end
    end
    return x1 - x0
end

local full_span = triangle_span()
tris = {}
ui.begin(layer, 512, 512, 1, false, math.pi / (2 * 1.7))
ui.logo(256, 256, 104)
ui.finish()
local edge_span = triangle_span()
check("the menu logo turns around its vertical axis",
      edge_span / full_span > 0.11 and edge_span / full_span < 0.12,
      string.format("span ratio %.3f", edge_span / full_span))
check("the turning logo draws a rear face and solid edge",
      #tris == 84, "triangles: " .. #tris)
local face_x0, face_x1 = math.huge, -math.huge
for _, tri in ipairs(tris) do
    if same_color(tri.col, pal.LOGO_ORANGE)
       or same_color(tri.col, pal.LOGO_CYAN) then
        for i = 1, 6, 2 do
            face_x0 = math.min(face_x0, tri[i])
            face_x1 = math.max(face_x1, tri[i])
        end
    end
end
check("the colored face reaches fully sideways",
      face_x1 - face_x0 < 0.000001,
      string.format("face span %.6f", face_x1 - face_x0))

tris = {}
ui.begin(layer, 512, 512, 1, false, math.pi / 1.7)
ui.logo(256, 256, 104)
ui.finish()
-- Read out of the drawing rather than written down again here. This was a
-- literal 0.30 in two places, so brightening the far face broke the test
-- rather than being measured by it.
local shade = tonumber(string.match(read_file("client/arena/ui.lua"),
                                    "MK_ORANGE_BACK%s*=%s*{pal%.LOGO_ORANGE%[1%]%s*%*%s*([%d%.]+)"))
check("the rear face has a shade to be drawn at", shade ~= nil,
      tostring(shade))
-- A face turned away is shaded, not switched off. Below about a third it
-- reads as black against this background, which is what it did.
check("and it is dark enough to read as the far side",
      shade and shade < 0.85, tostring(shade))
check("and light enough not to read as a hole",
      shade and shade > 0.45, tostring(shade))
local back_orange = {pal.LOGO_ORANGE[1] * shade,
                     pal.LOGO_ORANGE[2] * shade,
                     pal.LOGO_ORANGE[3] * shade, 1}
local back_cyan = {pal.LOGO_CYAN[1] * shade,
                   pal.LOGO_CYAN[2] * shade,
                   pal.LOGO_CYAN[3] * shade, 1}
local back_orange_n, back_cyan_n, bright_n = 0, 0, 0
for _, tri in ipairs(tris) do
    if same_color(tri.col, back_orange) then
        back_orange_n = back_orange_n + 1
    end
    if same_color(tri.col, back_cyan) then
        back_cyan_n = back_cyan_n + 1
    end
    if same_color(tri.col, pal.LOGO_ORANGE)
       or same_color(tri.col, pal.LOGO_CYAN) then
        bright_n = bright_n + 1
    end
end
check("the back half of the turn shows the dark rear face",
      #tris == 18 and back_orange_n == 4 and back_cyan_n == 6
      and bright_n == 0,
      string.format("triangles %d, dark %d/%d, bright %d",
                    #tris, back_orange_n, back_cyan_n, bright_n))

local ui_source = read_file("client/arena/ui.lua")
check("the game mesh stores the canonical colored outlines",
      has(ui_source, "42, 0, 84, 67, 66, 78, 42, 53, 18, 78, 0, 67")
      and has(ui_source, "0, 67, 18, 78, 42, 53, 66, 78, 84, 67")
      and has(ui_source, "60, 103, 42, 74, 24, 103"))
check("the game mesh stores one constant-width gap ring",
      has(ui_source, "-0.4977, 64.9379, 17.7531, 76.0912, 42, 50.834")
      and has(ui_source, "86.0621, 67.4977, 65.7531, 79.9088, 42, 55.166")
      and has(ui_source, "18.2469, 79.9088, -2.0621, 67.4977"))

local loader = read_file("client/tools/single_file.py")
check("the loading screen uses the canonical logo dimensions and colors",
      has(loader, "var MK_W = 84, MK_H = 104;")
      and has(loader, 'var LOGO_ORANGE = "#ff9d22", LOGO_CYAN = "#27c5ed";'))
check("the loading screen draws the canonical outer and shared edges",
      has(loader, "g.moveTo(42, 0); g.lineTo(84, 67); g.lineTo(66, 78);")
      and has(loader, "g.lineTo(42, 74); g.lineTo(24, 103);")
      and has(loader, "g.moveTo(0, 67); g.lineTo(18, 78); g.lineTo(42, 53);")
      and has(loader, 'g.lineWidth = 3;')
      and has(loader, 'g.lineCap = "square";'))
check("the loading progress bar still spans the complete lockup",
      has(loader, "g.fillRect(x0, by, span * progress, 2);"))

local function png_size(body)
    local function n32(i)
        local a, b, c, d = body:byte(i, i + 3)
        return ((a * 256 + b) * 256 + c) * 256 + d
    end
    if body:sub(1, 8) ~= "\137PNG\r\n\26\n" then return 0, 0 end
    return n32(17), n32(21)
end

for _, spec in ipairs({
    {"client/web/favicon-64.png", 64},
    {"client/web/apple-touch-icon.png", 180},
    {"client/web/icon-192.png", 192},
    {"client/web/icon-512.png", 512},
    {"deploy/discord/icon.png", 512},
}) do
    local pw, ph = png_size(read_file(spec[1]))
    check(spec[1] .. " has the declared size",
          pw == spec[2] and ph == spec[2], pw .. "x" .. ph)
end
check("the Discord icon is the canonical 512 px app tile",
      read_file("deploy/discord/icon.png")
      == read_file("client/web/icon-512.png"))

local function unb64(s)
    local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
                  .. "0123456789+/"
    local map = {}
    for i = 1, #chars do map[chars:sub(i, i)] = i - 1 end
    local out, bits, n = {}, 0, 0
    for c in s:gmatch(".") do
        local v = map[c]
        if v then
            bits, n = bits * 64 + v, n + 6
            if n >= 8 then
                n = n - 8
                out[#out + 1] = string.char(math.floor(bits / 2 ^ n) % 256)
                bits = bits % 2 ^ n
            end
        end
    end
    return table.concat(out)
end

local page = read_file("client/web/engine_template.html")
local assets = {
    {"the page embeds the source favicon",
     page:match('rel="icon" type="image/svg%+xml" '
                .. 'href="data:image/svg%+xml;base64,([^"]+)"'), favicon},
    {"the page embeds the 64 px fallback",
     page:match('rel="icon" type="image/png" sizes="64x64" '
                .. 'href="data:image/png;base64,([^"]+)"'),
     read_file("client/web/favicon-64.png")},
    {"the page embeds the Apple icon",
     page:match('rel="apple%-touch%-icon" '
                .. 'href="data:image/png;base64,([^"]+)"'),
     read_file("client/web/apple-touch-icon.png")},

}
for _, asset in ipairs(assets) do
    local name, encoded, source = asset[1], asset[2], asset[3]
    check(name, encoded and unb64(encoded) == source,
          encoded and "embedded bytes differ" or "data URI missing")
end

print(fails == 0 and "all good" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
