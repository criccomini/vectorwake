-- Who this pilot is, across sessions and across zones.
--
-- Nobody signs up. The first time this runs it asks the meta-layer for an
-- account, is handed a call sign with it, and stores the secret it gets
-- back; from then on a session is one exchange that returns a token the
-- arena checks for itself. docs/design/accounts.md is the model; the short
-- version is that the account exists before the first menu is drawn and the
-- player is never asked about it. A password is offered, never demanded,
-- and it is the whole of what "claimed" means.
--
-- Everything here is best effort. A deployment with no meta-layer, or one
-- whose meta-layer is down, leaves `M.token` empty, and an empty token still
-- flies: the arena seats an unknown guest under the generated call sign. What
-- is lost is the rating outliving the room, which is worth exactly one line in
-- the menu and no interruption at all.

local M = {}

-- Where to log in. Learned from the directory's games list, because that is
-- the one thing the client asks for before it needs an identity.
M.base = ""
M.token = ""
M.account = 0
M.name = ""
M.claimed = false
M.note = ""
-- What this pilot has banked, and what their account may slot. Both come back
-- with a session and neither is asserted by this client: the arena checks a
-- kit against the entitlements the token carries, and a purchase debits the
-- wallet at the meta-layer. These two copies are what the ship page draws,
-- with the shelf, so a client that edited them would fool only its own
-- screen.
M.rivets = 0
M.entitlements = {}
-- The kit this pilot has chosen, per hull, by the hull's own name. A hull with
-- no entry has never been taken to the ship page, and the arena deals it a
-- starter kit.
M.kits = {}
-- Three built-in templates followed by the builds this pilot has named.
-- Templates are hull-independent; `kits` above is still the active build for
-- each hull.
M.profiles = {}
-- The catalog, as the meta-layer lists it: one entry a slot the game has,
-- `{slot, label, owned, ceiling, base}`, with `price` and `note` on the ones
-- with a rung left to sell. Asked for when the page is opened rather than
-- carried by every session, because it is a page nobody is looking at most of
-- the time.
--
-- Nothing yet, which is not the same as a catalog with nothing in it: this is
-- the meta-layer's answer and a page that has not had one has to say so.
M.catalog = nil
-- Which Monday the table in hand starts on, as the meta-layer spells it.
M.week_since = ""
-- The week's table, as the meta-layer publishes it. Asked for the same way.
M.week = nil
-- The friends page's lists: friends with where they are flying, whoever has
-- added this pilot and is waiting on an answer, whoever this pilot has added
-- and is waiting on, and whoever is in the room right now and is on none of
-- the others. Every edge has exactly one home among those four, so the page
-- draws them without deciding anything. `have_friends` separates "waiting for
-- an answer" from "nobody yet", which are the same empty table and different
-- sentences.
M.friends = {}
M.asked = {}
M.waiting = {}
M.here = {}
M.have_friends = false
-- And everybody who has ever added this pilot, whatever came of it, each
-- carrying "waiting", "ignored" or "friend". The same edges again under a
-- heading that says so, which is what makes ignoring reversible: the add is
-- still there and accepting it later is one press.
M.everybody = {}
-- What the last press on this page came to, for the line under the add field.
-- Held here rather than in the menu because the answer arrives with a reply
-- and the menu is not the thing waiting for it.
M.friend_note = ""
M.friend_bad = false
-- Whether the meta-layer has ever answered. It separates "waiting" from
-- "there is nothing there", which are the same empty token and very different
-- sentences to show somebody.
M.reached = false

local secret = ""
-- One request of each kind in flight at a time. The games list re-asks the
-- directory every few seconds and every reply carries the meta-layer's
-- address, so without this the second reply starts a second account before the
-- first one has answered, and a session leaves an orphan behind it.
local minting = false
local signing_in = false
-- Which secret the request in flight belongs to, and a serial that makes its
-- reply harmless after another secret starts a newer session. A login can land
-- while the automatic session from page load is still traveling.
local signing_secret = nil
local session_serial = 0
local SAVE = sys.get_save_file("vectorwake", "account")
-- A token is good for fifteen minutes. Refreshing at ten leaves a wide margin
-- for a slow reply and for a player who sat in the menu.
local REFRESH = 600
local refreshed_at = -1e9

local function now()
    return socket and socket.gettime and socket.gettime() or os.time()
end

-- The page-level error reporter cannot see a Lua module. Hand it the public
-- account number and nothing else, so a browser failure can be tied to the
-- pilot an operator will inspect without putting the device secret in JavaScript.
local function publish_account()
    if html5 then
        pcall(html5.run, "window.vwAccount=" ..
                         tostring(math.max(0, math.floor(M.account or 0))))
    end
end

local function save()
    pcall(sys.save, SAVE, {secret = secret, account = M.account})
    publish_account()
end

local function load()
    local ok, d = pcall(sys.load, SAVE)
    if ok and type(d) == "table" and type(d.secret) == "string" then
        secret = d.secret
        M.account = type(d.account) == "number" and d.account or 0
    end
    publish_account()
end

-- One POST. Defold's http.request is the same call in a browser and on a
-- desktop, so there is one path here rather than one per platform.
local function post(path, body, cb)
    if M.base == "" then
        cb(nil, "no meta-layer")
        return
    end
    local url = M.base
    if not string.match(url, "^https?://") then url = "http://" .. url end
    http.request(url .. path, "POST", function(_, _, res)
        if not res or res.status ~= 200 then
            -- The body's reason where there is one. "That name and password
            -- do not match" is the sentence a card has to show; "meta-layer
            -- said 403" is a log line wearing its clothes.
            local why
            if res then
                local ok, parsed = pcall(json.decode, res.response or "")
                if ok and type(parsed) == "table"
                   and type(parsed.error) == "string" then
                    why = parsed.error
                end
                why = why or ("meta-layer said " .. tostring(res.status))
            end
            cb(nil, why or "no reply")
            return
        end
        M.reached = true
        local ok, parsed = pcall(json.decode, res.response or "")
        if not ok or type(parsed) ~= "table" then
            cb(nil, "unreadable reply")
            return
        end
        cb(parsed, nil)
    end, {["Content-Type"] = "application/json"}, json.encode(body or {}))
end

-- A session, from the device secret this client already holds. Called on the
-- frame the meta-layer's address becomes known and every ten minutes after.
-- This is also the heartbeat the guest sweeper reads: an account that has not
-- begun a session in a week is one the server hands back to the name pool.
local function session(done, force)
    -- Repeated directory replies may ask for the same missing token while its
    -- request is already in flight. A deliberate account change is forced and
    -- supersedes it; a different secret does so without needing the flag.
    if signing_in and signing_secret == secret and not force then return end
    session_serial = session_serial + 1
    local mine = session_serial
    local mine_secret = secret
    signing_in = true
    signing_secret = mine_secret
    post("/v1/session", {secret = mine_secret}, function(r, err)
        if mine ~= session_serial or mine_secret ~= secret then return end
        signing_in = false
        signing_secret = nil
        if not r then
            -- A refused secret means the account behind it is gone or banned,
            -- and either way this client cannot use it again. A guest swept
            -- after a quiet week lands here, and the repair is the same as
            -- the first run: ask to be somebody new.
            M.note = err or "cannot start a session"
            if err == "no such account" then
                secret = ""
                M.token = ""
                M.account = 0
                M.claimed = false
                save()
            end
            if done then done(false, M.note) end
            return
        end
        M.token = r.token or ""
        M.account = r.account or 0
        M.name = r.name or M.name
        M.claimed = r.claimed == true
        M.rivets = tonumber(r.rivets) or 0
        M.entitlements = type(r.entitlements) == "table" and r.entitlements or {}
        M.kits = type(r.kits) == "table" and r.kits or {}
        M.profiles = type(r.profiles) == "table" and r.profiles or {}
        M.note = ""
        refreshed_at = now()
        publish_account()
        if done then done(true) end
    end)
end

-- First contact. The server chooses the call sign: a name a client could
-- propose is a name a script could choose, and the fleet-wide uniqueness the
-- login model rests on is only real while the server does the choosing.
local function make_guest()
    if minting then return end
    minting = true
    post("/v1/guest", {}, function(r, err)
        minting = false
        if not r then
            M.note = err or "cannot reach the meta-layer"
            return
        end
        secret = r.secret or ""
        M.account = r.account or 0
        M.name = r.name or ""
        save()
        session()
    end)
end

-- Told where the meta-layer is, which the games list carries. Idempotent: the
-- list is re-asked every few seconds while it is on screen, and this only does
-- work when something has actually changed.
function M.aim(base)
    base = base or ""
    if base == "" then return end
    local moved = base ~= M.base
    M.base = base
    if secret == "" then
        if moved or M.token == "" then make_guest() end
    elseif moved or M.token == "" or now() - refreshed_at > REFRESH then
        session()
    end
end

function M.load()
    load()
end

-- Whether there is an account layer to talk to and an account to talk about,
-- which is what decides between asking the server for things and doing the
-- offline version.
function M.online()
    return M.base ~= "" and secret ~= ""
end

-- File one bounded gameplay diagnostic without putting the device secret in
-- it. The meta-layer treats the account number as context rather than proof,
-- just like the page-level error reporter does. A report is best effort: a
-- diagnostic endpoint must never become another dependency of flight.
function M.report_debug(report)
    if M.base == "" or type(report) ~= "table" then return false end
    if not report.account or report.account <= 0 then
        report.account = math.max(0, math.floor(M.account or 0))
    end
    if not report.build and sys and sys.get_config_string then
        report.build = sys.get_config_string("project.version", "dev")
    end
    if not report.user_agent and html5 and html5.run then
        local ok, value = pcall(html5.run, "navigator.userAgent")
        if ok and type(value) == "string" then report.user_agent = value end
    end
    post("/v1/client-debug", report, function() end)
    return true
end

-- Set the password, which is both claiming and changing: the caller holds a
-- valid device secret either way, and the old password, if there was one,
-- is replaced rather than joined.
function M.claim(password, cb)
    post("/v1/claim", {secret = secret, password = password}, function(r, err)
        if not r then
            M.note = err or "cannot set a password"
            if cb then cb(false, M.note) end
            return
        end
        M.claimed = true
        -- The label a pilot wears comes from the token, so it is stale until
        -- the next session. Ask for one now rather than leaving them reading
        -- "guest" after the thing that fixes it.
        session(function(ok, why)
            if cb then cb(ok, why) end
        end, true)
    end)
end

-- This device joining an account that already exists, by its name and
-- password. The answer is a secret of this device's own, which is what lets
-- one device be forgotten without taking the others with it.
function M.login(name, password, cb)
    post("/v1/login", {name = name, password = password}, function(r, err)
        if not r then
            M.note = err or "that did not work"
            if cb then cb(false, M.note) end
            return
        end
        secret = r.secret or ""
        M.account = r.account or 0
        M.token = ""
        save()
        session(function(ok, why)
            if cb then cb(ok, why) end
        end, true)
    end)
end

-- A fresh call sign from the pool. The account number stays, so the rating
-- and the record ride through the rename; only the label moves.
function M.rename(cb)
    post("/v1/rename", {secret = secret}, function(r, err)
        if not r then
            M.note = err or "cannot reroll"
            if cb then cb(false, M.note) end
            return
        end
        M.name = r.name or M.name
        if cb then cb(true) end
    end)
end

-- Walk away from the account on this device. The account itself stands, and
-- its password still opens it from anywhere; what is forgotten is this
-- device's way in. The next thing this client needs is to be somebody, so it
-- asks to be a fresh guest straight away.
-- A kit saved against a hull, so it comes back on the next device and the
-- next session.
--
-- The arena is told separately and does not wait for this: a kit takes effect
-- because the client sent it to the room, and this is what makes it survive
-- the tab closing. So a meta-layer that is down costs a player their loadout
-- tomorrow and nothing tonight, which is the same bargain every other durable
-- thing here makes.
function M.save_kit(class, kit)
    M.kits[class] = kit
    if M.base == "" then return end
    post("/v1/kit", {secret = secret, class = class, kit = kit}, function(r, err)
        if not r then M.note = err or "cannot save that kit" end
    end)
end

-- Keep the build in hand as a named template. The meta-layer returns the
-- canonical name, which matters when this updates an existing profile whose
-- capitalization differs from what was typed.
function M.save_profile(name, kit, cb)
    if M.base == "" then
        if cb then cb(false, "no meta-layer") end
        return
    end
    post("/v1/profile", {secret = secret, name = name, kit = kit},
         function(r, err)
             local profile = r and r.profile
             if type(profile) ~= "table" then
                 if cb then cb(false, err or "cannot save that profile") end
                 return
             end
             local replaced = false
             for i, old in ipairs(M.profiles) do
                 if old.builtin ~= true and type(old.name) == "string"
                    and string.lower(old.name) == string.lower(profile.name or "") then
                     M.profiles[i] = profile
                     replaced = true
                     break
                 end
             end
             if not replaced then M.profiles[#M.profiles + 1] = profile end
             if cb then cb(true, nil, profile) end
         end)
end

-- One step in one slot, bought. The price and what is left to buy are the
-- meta-layer's to decide: this asks, and the reply says what the slot now
-- holds and what is left in the wallet.
function M.buy(slot, zone, cb)
    if type(zone) == "function" then cb, zone = zone, "" end
    if M.base == "" then
        if cb then cb(false, "no meta-layer") end
        return
    end
    post("/v1/buy", {secret = secret, slot = slot, zone = zone or ""}, function(r, err)
        if not r then
            M.note = err or "cannot buy that"
            if cb then cb(false, M.note) end
            return
        end
        M.rivets = tonumber(r.rivets) or M.rivets
        -- The shelf, so the hangar can slot it at once rather than after the
        -- next session. This copy is what the screen draws.
        M.entitlements[(tonumber(r.slot) or 0) + 1] = tonumber(r.n) or 0
        M.note = ""
        -- And a fresh token, because the arena reads its copy rather than this
        -- one. Without this a purchase is invisible where it matters: the
        -- hangar lets you spend a point on what you just bought, the room
        -- checks a token minted before you bought it, and `sim_set_kit`
        -- refuses the whole kit rather than the one slot it cannot hold. So a
        -- pilot buys a barrel, slots it, flies, and is dealt the ship they had
        -- an hour ago with nothing on screen to say why. Forced, because the
        -- session in hand is valid and a refresh would otherwise be skipped.
        session(nil, true)
        if cb then cb(true) end
    end)
end

-- The catalog, and the week's table. Both are pages somebody is looking at
-- rather than facts a session needs, so they are asked for when the page opens
-- and left alone otherwise.
function M.refresh_upgrades(zone)
    if M.base == "" then return end
    post("/v1/upgrades", {secret = secret, zone = zone or ""}, function(r)
        if type(r) ~= "table" then return end
        if type(r.slots) == "table" then M.catalog = r.slots end
        -- And the wallet, which rides the same reply and was being dropped.
        -- Rivets are bounty taken, so a pilot earns them in a match rather
        -- than on this page: the number in hand is from whenever the session
        -- began, and the only thing that moved it was a purchase. An evening's
        -- kills showed up on the next reload.
        if tonumber(r.rivets) then M.rivets = tonumber(r.rivets) end
    end)
end

-- `back` is which week: zero is the one running, one is the week before it.
function M.refresh_week(back)
    if M.base == "" then return end
    post("/v1/week", {back = math.max(0, math.floor(back or 0))}, function(r)
        if type(r) ~= "table" then return end
        if type(r.week) == "table" then M.week = r.week end
        -- The Monday it starts on, so the page names the week it is showing
        -- rather than counting backwards from today itself.
        M.week_since = type(r.since) == "string" and r.since or ""
    end)
end

-- The deterministic film attached to one public result. It needs no account:
-- sharing a match means the person opening it can see it before they have ever
-- flown here themselves.
function M.fetch_replay(id, cb)
    post("/v1/replay", {id = id}, cb)
end

-- The friends page, whole: who you are friends with and where they are, who
-- has added you and is waiting, and who is in the room with you.
--
-- One request for three lists because they are one screen and because the
-- lists are defined against each other. Asking separately would leave a frame
-- where two replies disagree about which list somebody belongs in, and the
-- page would draw them twice. See docs/design/friends.md.
local function take_friends(r)
    if type(r) ~= "table" then return false end
    M.friends = type(r.friends) == "table" and r.friends or {}
    M.asked = type(r.asked) == "table" and r.asked or {}
    M.waiting = type(r.waiting) == "table" and r.waiting or {}
    M.here = type(r.here) == "table" and r.here or {}
    M.everybody = type(r.everybody) == "table" and r.everybody or {}
    M.have_friends = true
    return true
end

-- Arriving in a room, or leaving one, makes the last answer wrong.
--
-- Presence is answered for the room you are in: `here` is the roster of the
-- arena the meta-layer sees you in, so an answer given on the front end has
-- nobody in it and stays that way until the next one lands. The page went on
-- drawing that answer for as long as the round trip took and said "nobody
-- yet", which is a claim this client cannot make until it has asked from
-- where it is now. Forget it instead, and the page says it is asking.
function M.room_changed()
    M.here = {}
    M.have_friends = false
end

function M.refresh_friends()
    if M.base == "" then return end
    post("/v1/friends", {secret = secret}, function(r) take_friends(r) end)
end

-- One edge, made or dropped. The reply is the page, so a press redraws
-- without a second request and without this client guessing what the edge did
-- to lists it does not compute.
--
-- `other` is an account number off one of those lists, or a call sign
-- somebody typed. A name is the only way onto this page that does not start
-- with the two of you being in the same room, and it has to be exact: the
-- meta-layer looks it up whole and answers "no pilot called that" rather than
-- offering anybody.
function M.friend(other, add, cb)
    if M.base == "" then
        if cb then cb(false, "no meta-layer") end
        return
    end
    local body = {secret = secret, add = add ~= false}
    if type(other) == "string" then
        body.name = other
    else
        body.account = other
    end
    post("/v1/friend", body,
         function(r, err)
             if not r then
                 M.friend_note = err or "cannot do that"
                 M.friend_bad = true
                 M.note = M.friend_note
                 if cb then cb(false, M.friend_note) end
                 return
             end
             take_friends(r)
             M.note = ""
             -- Which sentence the add field says back. `mutual` is the one
             -- thing this client cannot work out for itself: once the row is
             -- in, the press that closed the pair and the press that did not
             -- look identical.
             M.friend_bad = false
             if add == false then
                 M.friend_note = ""
             elseif r.mutual then
                 M.friend_note = "friends. they had already added you."
             else
                 M.friend_note = "added. you are friends once they add you back."
             end
             if cb then cb(true, nil, r.mutual == true) end
         end)
end

-- Call signs beginning with what has been typed into the add field.
--
-- The one request in this client that names a pilot you have never met, and
-- the meta-layer keeps it small: eight names back, matched from the start of
-- the call sign. `serial` throws away an answer to a prefix
-- that is no longer what is in the box, because a keystroke and a round trip
-- do not arrive in order and a list that flickers back to an older prefix is
-- worse than no list.
M.found = {}
-- The prefix the names in hand are an answer to, which is not the same as the
-- one being asked about: a keystroke lands now and its reply lands later, and
-- in between the box says something the list does not. Set when the reply
-- arrives, so the page can tell whether what it is holding is about what is
-- on screen.
M.found_for = ""
local finding, asking = 0, ""
-- How little can be in the box and still be worth asking about. One
-- character: the meta-layer answers from the first letter, and a client that
-- held the first one back made a field that looks broken until the second.
local FIND_MIN = 1
function M.find_pilots(prefix)
    prefix = tostring(prefix or "")
    if M.base == "" or #prefix < FIND_MIN then
        M.found, M.found_for, asking = {}, prefix, prefix
        return
    end
    if prefix == asking then return end
    asking = prefix
    finding = finding + 1
    local mine = finding
    post("/v1/friend/find", {secret = secret, q = prefix}, function(r)
        if mine ~= finding then return end
        M.found = (type(r) == "table" and type(r.pilots) == "table")
            and r.pilots or {}
        M.found_for = prefix
    end)
end

-- An add taken off the list that asks about it, and put on the list of
-- everybody who has ever added you. Nothing is sent to them. Passing `false`
-- puts it back.
function M.ignore(other, on, cb)
    if M.base == "" then
        if cb then cb(false, "no meta-layer") end
        return
    end
    post("/v1/friend/ignore",
         {secret = secret, account = other, on = on ~= false},
         function(r, err)
             if not r then
                 M.friend_note = err or "cannot do that"
                 M.friend_bad = true
                 if cb then cb(false, M.friend_note) end
                 return
             end
             take_friends(r)
             M.friend_note = ""
             M.friend_bad = false
             if cb then cb(true) end
         end)
end

function M.logout()
    secret = ""
    M.token = ""
    M.account = 0
    M.claimed = false
    M.friends, M.asked, M.here = {}, {}, {}
    M.waiting, M.have_friends = {}, false
    M.everybody = {}
    M.found, M.found_for = {}, ""
    M.friend_note, M.friend_bad = "", false
    M.name = ""
    M.rivets = 0
    M.entitlements = {}
    M.kits = {}
    M.profiles = {}
    M.catalog = nil
    save()
    if M.base ~= "" then make_guest() end
end

-- There was a status() here, one line about this pilot for the menu to print:
-- claimed, guest on this device, signing in, no accounts on this deployment.
-- The menu stopped printing sentences under its lists and it was the last
-- caller. `M.note` still carries what went wrong, for a log rather than a
-- player.

return M
