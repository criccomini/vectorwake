-- The two public pages and the browser diagnostic bridge.
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

local function has(body, text)
    return body:find(text, 1, true) ~= nil
end

local landing = read("deploy/site/index.html")
local game = read("client/web/engine_template.html")
local arena = read("client/arena/arena.script")
local account = read("client/arena/account.lua")
local admin = read("deploy/admin/admin.js")

check("the landing page names its large share card",
      has(landing, 'property="og:image" content="https://vectorwake.net/share-card.png"')
      and has(landing, 'name="twitter:card" content="summary_large_image"'))
-- One card, named by both pages. The game page used to carry its own, which
-- meant two images to keep current and one of them was always the stale one:
-- a link to play.vectorwake.net and a link to vectorwake.net are the same game
-- and should not preview as two different products.
check("the game page names the same large share card",
      has(game, 'property="og:image" content="https://vectorwake.net/share-card.png"')
      and has(game, 'name="twitter:card" content="summary_large_image"'))
check("and no page still asks for the retired one",
      not has(game, "play-share-card") and not has(landing, "play-share-card"))
check("the game page reports bounded browser failures",
      has(game, "'/meta/v1/client-error'")
      and has(game, "sent >= 8")
      and has(game, "keepalive: true"))
check("the iPhone canvas continues behind Safari's lower toolbar",
      has(game, "var pageH = browser_page")
      and has(game, "height: 100lvh")
      and has(game, "Math.max(visible, layoutH, innerH, outerH, largeH)")
      and has(game, "html.vw-ios-browser body")
      and has(game, "document.documentElement.classList.toggle('vw-ios-browser', browser_page)")
      and has(game, "if (root.style.height !== page) root.style.height = page")
      and has(game, "if (body.style.height !== page) body.style.height = page")
      and has(game, "var bottom = Math.max(padB, covered)")
      and has(arena, "touch.safe_b = self.installed and 0"))
check("the reported account crosses the Lua page boundary",
      has(account, "window.vwAccount=")
      and has(game, "account: Number(window.vwAccount) || 0"))
check("the admin page reads browser error groups",
      has(admin, 'post("/v1/admin/errors"')
      and has(admin, "pilotLink(error.account"))
check("the admin page prints zero bandwidth instead of a blank cell",
      has(admin, "Number.isFinite(i.bw_per_player)"))

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
