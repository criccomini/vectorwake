-- Account requests can finish in a different order from the one they started
-- in. This drives a page-load session and a login through that crossing.
--
--     lua5.1 client/tests/account_test.lua

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

local requests = {}
local replies = {}
local saved = {secret = "old-secret", account = 1}

_G.sys = {
    get_save_file = function() return "account.save" end,
    load = function() return saved end,
    save = function(_, value) saved = value end,
}
_G.socket = {gettime = function() return 10 end}
_G.json = {
    encode = function() return "{}" end,
    decode = function(key) return replies[key] end,
}
_G.http = {
    request = function(url, method, cb)
        requests[#requests + 1] = {url = url, method = method, cb = cb}
    end,
}

local function answer(request, key, value, status)
    replies[key] = value
    request.cb(nil, nil, {status = status or 200, response = key})
end

local account = require("arena.account")
account.load()
account.aim("https://meta")
check("page load starts the saved account's session", #requests == 1,
      tostring(#requests))

-- A second directory reply carries the same meta address while the first
-- session is still running. It should share that attempt rather than start a
-- request every time the games list refreshes.
account.aim("https://meta")
check("the same missing token is asked for once", #requests == 1,
      tostring(#requests))

local logged = nil
account.login("new-name", "password", function(ok, why)
    logged = {ok = ok, why = why}
end)
check("login starts beside the old session", #requests == 2,
      tostring(#requests))

answer(requests[2], "login", {secret = "new-secret", account = 2})
check("login starts a session for its new secret", #requests == 3,
      tostring(#requests))
check("login waits for the token before succeeding", logged == nil,
      tostring(logged and logged.ok))

answer(requests[3], "new-session", {
    token = "new-token", account = 2, name = "new-name", claimed = true,
})
check("the new session completes the login", logged and logged.ok,
      tostring(logged and logged.why))
check("the new identity is active", account.account == 2
      and account.name == "new-name" and account.token == "new-token")

-- The page-load response arrives last. It belongs to the secret the login
-- replaced and may not put that identity back into the client.
answer(requests[1], "old-session", {
    token = "old-token", account = 1, name = "old-name", claimed = true,
})
check("the stale session cannot restore the old account", account.account == 2
      and account.name == "new-name" and account.token == "new-token")

-- Claiming changes what the token says without changing the device secret, so
-- it deliberately supersedes any ordinary refresh and also waits for its own
-- replacement token before telling the menu it is done.
local claimed = nil
account.claim("new-password", function(ok, why)
    claimed = {ok = ok, why = why}
end)
answer(requests[4], "claim", {})
check("claim waits for its replacement token", claimed == nil and #requests == 5,
      tostring(#requests))
answer(requests[5], "claimed-session", {
    token = "claimed-token", account = 2, name = "new-name", claimed = true,
})
check("claim completes with the current token", claimed and claimed.ok
      and account.token == "claimed-token")

if fails > 0 then os.exit(1) end
print("all good")
