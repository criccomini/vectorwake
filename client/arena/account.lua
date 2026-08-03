-- Who this pilot is, across sessions and across zones.
--
-- Nobody signs up. The first time this runs it asks the meta-layer for an
-- account and stores the secret it gets back, and from then on a session is
-- one login that returns a token the arena checks for itself. docs/design/
-- accounts.md is the model; the short version is that the account exists
-- before the first menu is drawn and the player is never asked about it.
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
-- The account key, held only long enough to be shown once after a claim. It
-- is never written to disk: a key stored beside the secret it protects is a
-- second copy of the same thing, and the player was told to keep it.
M.key = ""
M.link_code = ""

local secret = ""
-- One request of each kind in flight at a time. The games list re-asks the
-- directory every few seconds and every reply carries the meta-layer's
-- address, so without this the second reply starts a second account before the
-- first one has answered, and a session leaves an orphan behind it.
local minting = false
local signing_in = false
local SAVE = sys.get_save_file("vectorwake", "account")
-- A token is good for fifteen minutes. Refreshing at ten leaves a wide margin
-- for a slow reply and for a player who sat in the menu.
local REFRESH = 600
local refreshed_at = -1e9

local function now()
    return socket and socket.gettime and socket.gettime() or os.time()
end

local function save()
    pcall(sys.save, SAVE, {secret = secret, account = M.account})
end

local function load()
    local ok, d = pcall(sys.load, SAVE)
    if ok and type(d) == "table" and type(d.secret) == "string" then
        secret = d.secret
        M.account = type(d.account) == "number" and d.account or 0
    end
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
            cb(nil, res and ("meta-layer said " .. tostring(res.status)) or "no reply")
            return
        end
        local ok, parsed = pcall(json.decode, res.response or "")
        if not ok or type(parsed) ~= "table" then
            cb(nil, "unreadable reply")
            return
        end
        cb(parsed, nil)
    end, {["Content-Type"] = "application/json"}, json.encode(body or {}))
end

-- A session, from whatever this client already holds. Called on the frame the
-- meta-layer's address becomes known and every ten minutes after.
local function login()
    if signing_in then return end
    signing_in = true
    post("/v1/login", {secret = secret}, function(r, err)
        signing_in = false
        if not r then
            -- A refused secret means the account behind it is gone or banned,
            -- and either way this client cannot use it again. Anything else is
            -- the service being unreachable, which is temporary.
            M.note = err or "cannot log in"
            return
        end
        M.token = r.token or ""
        M.account = r.account or 0
        M.name = r.name or M.name
        M.claimed = r.claimed == true
        M.note = ""
        refreshed_at = now()
    end)
end

-- First contact. The generated call sign travels with it, so the word list
-- lives in one place in this codebase rather than two that drift.
local function make_guest(name)
    if minting then return end
    minting = true
    post("/v1/guest", {name = name}, function(r, err)
        minting = false
        if not r then
            M.note = err or "cannot reach the meta-layer"
            return
        end
        secret = r.secret or ""
        M.account = r.account or 0
        M.name = r.name or name
        save()
        login()
    end)
end

-- Told where the meta-layer is, which the games list carries. Idempotent: the
-- list is re-asked every few seconds while it is on screen, and this only does
-- work when something has actually changed.
function M.aim(base, name)
    base = base or ""
    if base == "" then return end
    local moved = base ~= M.base
    M.base = base
    if secret == "" then
        if moved or M.token == "" then make_guest(name) end
    elseif moved or M.token == "" or now() - refreshed_at > REFRESH then
        login()
    end
end

function M.load()
    load()
end

-- Attach a way back in. The key is shown once and never stored, which is the
-- whole of what makes it worth having: a key kept beside the secret protects
-- nothing.
function M.claim(cb)
    post("/v1/claim", {secret = secret}, function(r, err)
        if not r then
            M.note = err or "cannot claim"
            if cb then cb(false) end
            return
        end
        M.key = r.key or ""
        M.claimed = true
        -- The label a pilot wears comes from the token, so it is stale until
        -- the next login. Ask for one now rather than leaving them reading
        -- "unknown" after the thing that fixes it.
        login()
        if cb then cb(true) end
    end)
end

-- A code another device can type. Short-lived and single use.
function M.link(cb)
    post("/v1/link/new", {secret = secret}, function(r, err)
        if not r then
            M.note = err or "cannot make a code"
            if cb then cb(false) end
            return
        end
        M.link_code = r.code or ""
        if cb then cb(true) end
    end)
end

-- This device joining an account that already exists, by key or by code. Both
-- answer with a secret of this device's own, which is what lets one device be
-- forgotten without taking the others with it.
local function adopt(path, body, cb)
    post(path, body, function(r, err)
        if not r then
            M.note = err or "that did not work"
            if cb then cb(false) end
            return
        end
        secret = r.secret or ""
        M.account = r.account or 0
        M.token = ""
        save()
        login()
        if cb then cb(true) end
    end)
end

function M.redeem_key(key, cb)
    adopt("/v1/redeem", {key = key}, cb)
end

function M.redeem_code(code, cb)
    adopt("/v1/link/redeem", {code = code}, cb)
end

-- What the menu says about this pilot, in one line.
function M.status()
    if M.base == "" then return "this deployment has no accounts; nothing is saved" end
    if M.token == "" then return M.note ~= "" and M.note or "signing in" end
    if M.claimed then return "claimed, so your rating follows you" end
    return "a guest on this device only"
end

return M
