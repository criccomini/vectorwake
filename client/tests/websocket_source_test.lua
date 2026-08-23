-- Native workers must not observe a half-built connection, and socket
-- backpressure must leave the worker instead of turning into a hot loop.

local function read(path)
    local file = assert(io.open(path, "rb"))
    local source = file:read("*a")
    file:close()
    return source
end

local websocket = read("client/websocket/src/websocket.cpp")
local pushed = assert(websocket:find(
    "g_Websocket.m_Connections.Push(conn);", 1, true))
local started = assert(websocket:find("StartConnection(conn);", pushed, true))
assert(started > pushed, "the connection worker starts before publication")

local socket = read("client/websocket/src/socket.cpp")
local send_at = assert(socket:find("dmSocket::Result Send", 1, true))
local receive_at = assert(socket:find("dmSocket::Result Receive", send_at, true))
local send = socket:sub(send_at, receive_at - 1)
assert(send:find("WaitForSocket", 1, true),
       "the handshake retries without waiting for socket readiness")
assert(send:find("if (out_sent_bytes)", 1, true),
       "wslay cannot return a partial write on backpressure")

print("websocket source contract tests pass")
