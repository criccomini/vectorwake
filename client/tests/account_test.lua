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
local page_scripts = {}
-- What the last body handed to the encoder was, so a request can be checked
-- for what it carried and not only for where it went. The encoder answers
-- with a constant, which is all the transport needs and none of what a test
-- reading the body needs.
local sent = nil

_G.sys = {
    get_save_file = function() return "account.save" end,
    get_config_string = function() return "test-build" end,
    load = function() return saved end,
    save = function(_, value) saved = value end,
}
_G.socket = {gettime = function() return 10 end}
_G.json = {
    encode = function(v) sent = v return "{}" end,
    decode = function(key) return replies[key] end,
}
_G.http = {
    request = function(url, method, cb)
        requests[#requests + 1] = {url = url, method = method, cb = cb,
                                   body = sent}
        sent = nil
    end,
}
_G.html5 = {
    run = function(script)
        page_scripts[#page_scripts + 1] = script
        return ""
    end,
}

local function answer(request, key, value, status)
    replies[key] = value
    request.cb(nil, nil, {status = status or 200, response = key})
end

local account = require("arena.account")
account.load()
check("the saved account is published to browser diagnostics",
      page_scripts[#page_scripts] == "window.vwAccount=1",
      tostring(page_scripts[#page_scripts]))
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
    ratings = {{class = "melee", rating = 1512, games = 3}},
})
check("the new session completes the login", logged and logged.ok,
      tostring(logged and logged.why))
check("the new identity is active", account.account == 2
      and account.name == "new-name" and account.token == "new-token")
check("the new account reaches the browser reporter",
      page_scripts[#page_scripts] == "window.vwAccount=2",
      tostring(page_scripts[#page_scripts]))

-- A session says whether this pilot has ever been rated, off the per-zone
-- rows it already carries. It is the one question the guest warning asks and
-- it costs no request of its own.
check("a session settles the login without a second request", #requests == 3,
      tostring(#requests))
check("a rated zone on the session marks the account rated",
      account.rated == true, tostring(account.rated))

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
-- A claimed pilot has nothing this warning is about, and the session that
-- carried no rated zone says so rather than leaving the last answer standing.
check("a session with no rated zone marks the account unrated",
      account.rated == false, tostring(account.rated))

local report = {kind = "local_correction"}
check("a gameplay diagnostic is accepted without a credential",
      account.report_debug(report) and #requests == 6)
check("the diagnostic carries public context only",
      requests[6].url == "https://meta/v1/client-debug"
      and requests[6].method == "POST"
      and report.account == 2 and report.build == "test-build")

local at = #requests
account.fetch_replay(42, function() end)
check("a public match film needs no account credential",
      requests[at + 1].url == "https://meta/v1/replay"
      and requests[at + 1].body.id == 42
      and requests[at + 1].body.secret == nil)

if fails > 0 then os.exit(1) end
print("all good")
