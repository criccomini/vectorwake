-- Static artifacts shared by the public site and the game page. Browser
-- behavior is exercised from web_shell_behavior_test.js, viewport_test.js,
-- and link_bridge_test.js against the shipping JavaScript.
--
--     lua5.1 client/tests/web_shell_test.lua

local fails = 0

local function check(name, ok, detail)
    if ok then
        print("ok   " .. name)
    else
        fails = fails + 1
        print("FAIL " .. name .. (detail and (": " .. detail) or ""))
    end
end

local function read(path, binary)
    local file = assert(io.open(path, binary and "rb" or "r"),
                        "run me from the repository root")
    local body = file:read("*a")
    file:close()
    return body
end

local function attrs(text)
    local out = {}
    for key, value in text:gmatch('([%w:_-]+)%s*=%s*"([^"]*)"') do
        out[key] = value
    end
    for key, value in text:gmatch("([%w:_-]+)%s*=%s*'([^']*)'") do
        out[key] = value
    end
    return out
end

local function meta(body, key, value)
    for text in body:gmatch("<meta%s+([^>]-)>") do
        local at = attrs(text)
        if at[key] == value then return at end
    end
    return nil
end

local function attribute_contains(body, wanted)
    for text in body:gmatch("<[^>]+>") do
        for _, value in pairs(attrs(text)) do
            if value:find(wanted, 1, true) then return true end
        end
    end
    return false
end

local landing = read("deploy/site/index.html")
local game = read("client/web/engine_template.html")

local landing_image = meta(landing, "property", "og:image")
local landing_card = meta(landing, "name", "twitter:card")
local game_image = meta(game, "property", "og:image")
local game_card = meta(game, "name", "twitter:card")

check("the landing page names its large share card",
      landing_image and landing_image.content ==
          "https://vectorwake.net/share-card.png"
      and landing_card and landing_card.content == "summary_large_image")
-- One card, named by both pages. The game page used to carry its own, which
-- meant two images to keep current and one of them was always the stale one:
-- a link to play.vectorwake.net and a link to vectorwake.net are the same game
-- and should not preview as two different products.
check("the game page names the same large share card",
      game_image and landing_image
      and game_image.content == landing_image.content
      and game_card and game_card.content == "summary_large_image")
check("and no page still asks for the retired one",
      not attribute_contains(game, "play-share-card")
      and not attribute_contains(landing, "play-share-card"))

local function png_size(path)
    local body = read(path, true)
    if body:sub(1, 8) ~= "\137PNG\13\10\26\10" or #body < 24 then return 0, 0 end
    local function u32(at)
        local a, b, c, d = body:byte(at, at + 3)
        return ((a * 256 + b) * 256 + c) * 256 + d
    end
    return u32(17), u32(21)
end

local width, height = png_size("deploy/site/share-card.png")
check("share-card.png is the social-card size", width == 1200 and height == 630,
      width .. "x" .. height)

if fails > 0 then os.exit(1) end
