package.path = "client/?.lua;" .. package.path

local callbacks = {}
local sent, disconnected, messages, losses = {}, 0, {}, {}

websocket = {
    DATA_TYPE_BINARY = 2,
    EVENT_CONNECTED = 1,
    EVENT_MESSAGE = 2,
    EVENT_DISCONNECTED = 3,
    EVENT_ERROR = 4,
}
function websocket.connect(url, _, callback)
    callbacks[url] = callback
    return url
end
function websocket.send(connection, message)
    sent[#sent + 1] = {connection, message}
end
function websocket.disconnect()
    disconnected = disconnected + 1
end

local progress, wire = 0, nil
local transport = require("arena.net_transport").new()
transport:configure({
    join_message = function() return "join" end,
    message = function(message) messages[#messages + 1] = message end,
    lost = function(reason) losses[#losses + 1] = reason end,
    progress = function() progress = progress + 1 end,
    wire = function(value) wire = value end,
})

assert(transport:connect({url = "wss://zone", wt = "", zone = "alpha"}))
assert(wire == "ws" and transport:info().secure)
callbacks["wss://zone"](nil, "socket", {event = websocket.EVENT_CONNECTED})
assert(sent[1][1] == "socket" and sent[1][2] == "join")
callbacks["wss://zone"](nil, "socket", {
    event = websocket.EVENT_MESSAGE,
    message = "world",
})
assert(messages[1] == "world")
transport:invalidate()
callbacks["wss://zone"](nil, "socket", {event = websocket.EVENT_DISCONNECTED})
assert(#losses == 0)
transport:hangup()
assert(disconnected == 1 and not transport:has_wire())

print("net transport tests pass")
