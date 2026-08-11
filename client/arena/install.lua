-- Getting this onto a home screen.
--
-- Two platforms, two different things, and the difference is not ours to fix.
-- Chrome hands the page the install and waits to be asked, so there the menu
-- offers one row and one tap. Safari has no such call, and every browser on an
-- iPhone is Safari underneath, so there the row can only say where the button
-- is: share sheet, Add to Home Screen. Anybody claiming otherwise is claiming
-- an API WebKit does not have.
--
-- The page answers all of it, in `vwInstallState` in the template. This is the
-- Lua side of that one string, cached, because a settings row's detail is
-- asked for on every frame it is drawn and this is a question whose answer
-- changes twice in a session at most: once when Chrome offers, once when
-- somebody accepts.

local M = {}

-- How long a cached answer stands. The offer arrives a second or two after
-- load, so this is short enough that a player who opens the menu straight away
-- sees the row appear rather than having to leave and come back.
local EVERY = 1.0

local state = nil
local age = EVERY

local function ask()
    if html5 == nil then return nil end
    local ok, r = pcall(html5.run, "window.vwInstallState" ..
                                   " ? window.vwInstallState() : ''")
    if not ok or type(r) ~= "string" or r == "" then return nil end
    return r
end

-- "tap" where the browser will install on request, "share" where the only way
-- in is the sheet, and nil where it is already installed, or the machine has
-- no home screen, or this is not the web.
function M.state()
    if age >= EVERY then
        age = 0
        state = ask()
    end
    return state
end

function M.tick(dt)
    age = age + (dt or 0)
end

-- Ask for it. Only ever means anything in the "tap" case; the sheet cannot be
-- opened from here, which is the whole reason the other case exists.
function M.go()
    if html5 == nil then return false end
    local ok = pcall(html5.run, "window.vwInstall && window.vwInstall()")
    -- Whatever the answer, the offer is spent: Chrome hands it over once.
    state = nil
    age = 0
    return ok
end

return M
