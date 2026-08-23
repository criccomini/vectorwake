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
local match_page = read("deploy/site/match.html")
local week_page = read("deploy/site/week.html")
local growth = read("deploy/site/growth.js")

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
check("the game page accepts room and replay routes",
      has(game, "^(join|watch|replay)\\/")
      and has(arena, "^replay/(%d+)$")
      and has(arena, "session.replay(self, reply)"))
check("match sharing uses the phone's native share sheet",
      has(game, "navigator.share({title: 'Vectorwake', url: url})")
      and has(game, "navigator.clipboard.writeText(url)"))
check("the iPhone canvas continues behind Safari's lower toolbar",
      has(game, "function vwPageHeight(")
      and has(game, "var pageH = vwPageHeight(")
      and has(game, "height: 100lvh")
      and has(game, "var landscape = width > visible")
      and has(game, "? Math.min(screenW, screenH)")
      and has(game, "h > screenAxisH + 2")
      and has(game, "html.vw-ios-surface body")
      and has(game, "document.documentElement.classList.toggle('vw-ios-surface', extended_page)")
      and has(game, "if (root.style.height !== page) root.style.height = page")
      and has(game, "if (body.style.height !== page) body.style.height = page")
      and has(game, "function vwSafeInsets(")
      and has(game, "var bottom = Math.max(padBottom, covered)")
      and has(game, "var safe = vwSafeInsets(")
      and has(arena, "touch.safe_b = (self.safe_b or 0) * density"))
check("the reported account crosses the Lua page boundary",
      has(account, "window.vwAccount=")
      and has(game, "account: Number(window.vwAccount) || 0"))
check("the admin page reads browser error groups",
      has(admin, 'post("/v1/admin/errors"')
      and has(admin, "pilotLink(error.account"))
check("the admin page reads structured rollback reports",
      has(admin, 'post("/v1/admin/debug"')
      and has(admin, "report.correction_px.toFixed(1)")
      and has(admin, "report.snapshot_gap_ms.toFixed(1)")
      and has(admin, "report.local_debt_px.toFixed(2)")
      and has(admin, "report.repel_after_speed.toFixed(2)")
      and has(admin, "report.clock_adjust"))
check("the admin page prints zero bandwidth instead of a blank cell",
      has(admin, "Number.isFinite(i.bw_per_player)"))
check("public match pages expose score, film, and sharing",
      has(match_page, "data-score") and has(match_page, "data-replay")
      and has(match_page, "data-share") and has(growth, 'request("/v1/match"')
      and has(growth, "error.status !== 404"))
check("the weekly recap is a shareable public artifact",
      has(week_page, "data-stories") and has(week_page, "data-share")
      and has(growth, 'request("/v1/week"'))

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
