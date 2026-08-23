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

local report = {kind = "local_correction"}
check("a gameplay diagnostic is accepted without a credential",
      account.report_debug(report) and #requests == 6)
check("the diagnostic carries public context only",
      requests[6].url == "https://meta/v1/client-debug"
      and requests[6].method == "POST"
      and report.account == 2 and report.build == "test-build")

-- A purchase raises what this account may slot, and the arena reads that off
-- the token rather than off this client. So buying has to mint a new one.
--
-- Without it the failure is silent and expensive: the hangar lets a pilot
-- spend a point on what they just bought, the room checks a token minted
-- before the purchase, and `sim_set_kit` refuses the whole kit rather than the
-- one slot it cannot hold. The pilot flies the ship they had an hour ago and
-- nothing on screen says why. Found by buying a barrel, slotting it, and
-- watching a single round leave the gun.
local before = #requests
local bought = nil
account.buy(13, function(ok) bought = ok end)
check("buying asks the meta-layer", #requests == before + 1
      and requests[before + 1].url == "https://meta/v1/buy",
      requests[before + 1] and requests[before + 1].url or "no request")
answer(requests[before + 1], "buy", {slot = 13, n = 1, rivets = 65})
check("the purchase lands", bought == true and account.rivets == 65,
      tostring(bought) .. "/" .. tostring(account.rivets))
check("and this client can draw it at once",
      account.entitlements[14] == 1, tostring(account.entitlements[14]))
check("and a fresh token is asked for, since the arena reads that copy",
      #requests == before + 2
      and requests[before + 2].url == "https://meta/v1/session",
      requests[before + 2] and requests[before + 2].url or "no session")
answer(requests[before + 2], "post-buy", {
    token = "bought-token", account = 2, name = "new-name", claimed = true,
    entitlements = {[14] = 1},
})
check("and the token the arena will check carries it",
      account.token == "bought-token", account.token)

-- Arriving in a room makes the last friends answer wrong: it was given for
-- wherever this client was before, and `here` is a fact about the room. The
-- page said "nobody yet" for the length of the round trip that followed,
-- which is a claim it could not make until it had asked from the new room.
local at = #requests
account.refresh_friends()
answer(requests[at + 1], "friends",
       {friends = {}, asked = {}, waiting = {},
        here = {{account = 9, name = "Kestrel 9"}}})
check("the friends page arrives whole", account.have_friends == true
      and #account.here == 1, tostring(#account.here))
account.room_changed()
check("and a room change forgets who was beside you",
      account.have_friends == false and #account.here == 0,
      tostring(account.have_friends) .. "/" .. tostring(#account.here))

-- A call sign rather than an account number. It is the one way onto that page
-- that does not begin with the two of you being in the same room, and it goes
-- out as a name because this client has no way to turn one into a number.
at = #requests
account.friend("Halcyon 1", true)
check("a typed call sign goes out as a name",
      requests[at + 1].body.name == "Halcyon 1"
      and requests[at + 1].body.account == nil,
      tostring(requests[at + 1].body.name))

-- What came of it, in the sentence under the field. Adding somebody who had
-- already added you closes the pair, and after the row is in, that press and
-- the one that did not look identical: `mutual` is the only thing that
-- separates them and it comes back with the page.
answer(requests[at + 1], "friend",
       {friends = {}, asked = {}, waiting = {}, here = {},
        everybody = {{account = 7, name = "Halcyon 1", state = "friend"}},
        mutual = true})
check("and a pair that closed says so",
      account.friend_note ~= nil
      and string.find(account.friend_note, "friends", 1, true) == 1
      and account.friend_bad == false, tostring(account.friend_note))
check("with everybody who added you alongside the rest",
      #account.everybody == 1 and account.everybody[1].state == "friend",
      tostring(#account.everybody))

at = #requests
account.friend(5, true)
answer(requests[at + 1], "friend",
       {friends = {}, asked = {}, waiting = {}, here = {}, everybody = {},
        mutual = false})
check("and one that did not says what is still missing",
      string.find(account.friend_note, "add you back", 1, true) ~= nil,
      tostring(account.friend_note))

-- Ignoring is its own route, because it is not an edge: the add stays where
-- it is and comes off the list that asks about it.
at = #requests
account.ignore(9, true)
check("ignoring names the pilot and says which way",
      string.find(requests[at + 1].url, "/v1/friend/ignore", 1, true) ~= nil
      and requests[at + 1].body.account == 9
      and requests[at + 1].body.on == true,
      tostring(requests[at + 1].url))

at = #requests
account.fetch_replay(42, function() end)
check("a public match film needs no account credential",
      requests[at + 1].url == "https://meta/v1/replay"
      and requests[at + 1].body.id == 42
      and requests[at + 1].body.secret == nil)

if fails > 0 then os.exit(1) end
print("all good")
